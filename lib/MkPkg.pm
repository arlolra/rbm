package MkPkg;

use warnings;
use strict;
use Cwd qw(getcwd);
use YAML::XS qw(LoadFile);
use Template;
use File::Basename;
use IO::Handle;
use IO::CaptureOutput qw(capture_exec);
use File::Temp;
use File::Copy;
use File::Slurp;
use File::Path qw(make_path);
use String::ShellQuote;
use Sort::Versions;
use MkPkg::DefaultConfig;
#use Data::Dump qw/dd/;

our $config;

sub load_config_file {
    eval {
        LoadFile($_[0]);
    } or do {
        exit_error("Error reading file $_[0] :\n" . $@);
    }
}

sub load_config {
    my $config_file = shift // find_config_file();
    $config = { %default_config, %{ load_config_file($config_file) } };
    $config->{basedir} = dirname($config_file);
    foreach my $p (glob path($config->{projects_dir}) . '/*') {
        next unless -f "$p/config";
        $config->{projects}{basename($p)} = load_config_file("$p/config");
    }
}

sub load_system_config {
    my ($project) = @_;
    my $cfile = project_config($project ? $project : 'undef', 'sysconf_file');
    $config->{system} = -f $cfile ? load_config_file($cfile) : {};
}

sub find_config_file {
    for (my $dir = getcwd; $dir ne '/'; $dir = dirname($dir)) {
        return "$dir/mkpkg.conf" if -f "$dir/mkpkg.conf";
    }
    exit_error("Can't find config file");
}

sub path {
    my ($path, $basedir) = @_;
    $basedir //= $config->{basedir};
    return ( $path =~ m|^/| ) ? $path : "$basedir/$path";
}

sub config_p {
    my $project = shift;
    my $c = $config;
    foreach my $p (@_) {
        return undef unless defined $c->{$p};
        $c->{$p} = $c->{$p}->($project, @_) if ref $c->{$p} eq 'CODE';
        $c = $c->{$p};
    }
    return $c;
}

sub config {
    my $project = shift;
    my $name = shift;
    foreach my $path (@_) {
        my $r = config_p($project, @$path, @$name);
        return $r if defined $r;
    }
    return config_p($project, @$name);
}

sub notmpl {
    my ($name, $project) = @_;
    return 1 if $name eq 'notmpl';
    my @n = (@{$config->{notmpl}}, @{project_config($project, 'notmpl')});
    return grep { $name eq $_ } @n;
}

sub confkey_str {
    ref $_[0] eq 'ARRAY' ? join '/', @{$_[0]} : $_[0];
}

sub project_config {
    my ($project, $name, $options) = @_;
    $name = [ split '/', $name ] unless ref $name eq 'ARRAY';
    my $opt_save = $config->{opt};
    $config->{opt} = { %{$config->{opt}}, %$options } if $options;
    my $res = config($project, $name, ['opt'], ['run'],
                        ['projects', $project], [], ['system']);
    if (!$options->{no_tmpl} && defined($res) && !ref $res
        && !notmpl(confkey_str($name), $project)) {
        $res = process_template($project, $res,
            confkey_str($name) eq 'output_dir' ? '.' : undef);
    }
    $config->{opt} = $opt_save;
    if (!defined($res) && $options->{error_if_undef}) {
        my $msg = $options->{error_if_undef} eq '1' ?
                "Option " . confkey_str($name) . " is undefined"
                : $options->{error_if_undef};
        exit_error($msg);
    }
    return $res;
}

sub exit_error {
    print STDERR "Error: ", $_[0], "\n";
    exit (exists $_[1] ? $_[1] : 1);
}

sub get_distribution {
    my ($project) = @_;
    my $distribution = project_config($project, 'distribution')
                || exit_error 'No distribution specified';
    exists $config->{distributions}{$distribution}
                || exit_error "Unknown distribution $distribution";
    return $distribution;
}

sub set_git_gpg_wrapper {
    my ($project) = @_;
    my $w = project_config($project, 'gpg_wrapper');
    my (undef, $tmp) = File::Temp::tempfile();
    write_file($tmp, $w);
    chmod 0700, $tmp;
    system('git', 'config', 'gpg.program', $tmp) == 0
        || exit_error 'Error setting gpg.program';
    return $tmp;
}

sub unset_git_gpg_wrapper {
    unlink $_[0];
    system('git', 'config', '--unset', 'gpg.program') == 0
        || exit_error 'Error unsetting gpg.program';
}

sub git_commit_sign_id {
    my ($project, $chash) = @_;
    my $w = set_git_gpg_wrapper($project);
    my ($stdout, $stderr, $success, $exit_code) =
        capture_exec('git', 'log', "--format=format:%G?\n%GG", -1, $chash);
    unset_git_gpg_wrapper($w);
    return undef unless $success;
    my @l = split /\n/, $stdout;
    return undef unless @l >= 2;
    return undef unless $l[0] =~ m/^[GU]$/;
    foreach (@l) {
        if (m/^Primary key fingerprint:(.+)$/) {
            my $fp = $1;
            $fp =~ s/\s//g;
            return $fp;
        }
    }
    return undef;
}

sub git_tag_sign_id {
    my ($project, $tag) = @_;
    my $w = set_git_gpg_wrapper($project);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'tag', '-v', $tag);
    unset_git_gpg_wrapper($w);
    return undef unless $success;
    foreach my $l (split /\n/, $stderr) {
        if ($l =~ m/^Primary key fingerprint:(.+)$/) {
            my $fp = $1;
            $fp =~ s/\s//g;
            return $fp;
        }
    }
    return undef;
}

sub valid_id {
    my ($fp, $valid_id) = @_;
    if ($valid_id eq '1' || (ref $valid_id eq 'ARRAY' && @$valid_id == 1
            && $valid_id->[0] eq '1')) {
        return 1;
    }
    if (ref $valid_id eq 'ARRAY') {
        foreach my $v (@$valid_id) {
            return 1 if $fp =~ m/$v$/;
        }
        return undef;
    }
    return $fp =~ m/$valid_id$/;
}

sub valid_project {
    my ($project) = @_;
    exists $config->{projects}{$project}
        || exit_error "Unknown project $project";
}

sub create_dir {
    my ($directory) = @_;
    return $directory if -d $directory;
    my @res = make_path($directory);
    exit_error "Error creating $directory" unless @res;
    return $directory;
}

sub git_clone_fetch_chdir {
    my $project = shift;
    my $clonedir = create_dir(path(project_config($project, 'git_clone_dir')));
    if (!chdir path("$clonedir/$project")) {
        chdir $clonedir || exit_error "Can't enter directory $clonedir: $!";
        if (system('git', 'clone',
                $config->{projects}{$project}{git_url}, $project) != 0) {
            exit_error "Error cloning $config->{projects}{$project}{git_url}";
        }
        chdir($project) || exit_error "Error entering $project directory";
    }
    if (!$config->{projects}{$project}{fetched} && project_config($project, 'fetch')) {
        system('git', 'checkout', '-q', '--detach', 'master') == 0
                || exit_error "Error checking out master";
        system('git', 'fetch', 'origin', '+refs/heads/*:refs/heads/*') == 0
                || exit_error "Error fetching git repository";
        system('git', 'fetch', 'origin', '+refs/tags/*:refs/tags/*') == 0
                || exit_error "Error fetching git repository";
        $config->{projects}{$project}{fetched} = 1;
    }
}

sub run_script {
    my ($cmd, $f) = @_;
    $f //= \&capture_exec;
    my @res;
    if ($cmd =~ m/^#/) {
        my (undef, $tmp) = File::Temp::tempfile();
        write_file($tmp, $cmd);
        chmod 0700, $tmp;
        @res = $f->($tmp);
        unlink $tmp;
    } else {
        @res = $f->($cmd);
    }
    return @res == 1 ? $res[0] : @res;
}

sub execute {
    my ($project, $cmd) = @_;
    my $git_hash = project_config($project, 'git_hash')
        || exit_error 'No git_hash specified';
    my $old_cwd = getcwd;
    git_clone_fetch_chdir($project);
    my ($stdout, $stderr, $success, $exit_code)
        = capture_exec('git', 'checkout', $git_hash);
    exit_error "Cannot checkout $git_hash" unless $success;
    ($stdout, $stderr, $success, $exit_code)
                = run_script($cmd, \&capture_exec);
    chdir($old_cwd);
    chomp $stdout;
    return $success ? $stdout : undef;
}

sub gpg_id {
    my ($id) = @_;
    return $id unless $id;
    if (ref $id eq 'ARRAY' && @$id == 1 && !$id->[0]) {
        return 0;
    }
    return $id;
}

sub maketar {
    my ($project, $dest_dir) = @_;
    $dest_dir //= create_dir(path(project_config($project, 'output_dir')));
    valid_project($project);
    my $git_hash = project_config($project, 'git_hash')
        || exit_error 'No git_hash specified';
    my $old_cwd = getcwd;
    git_clone_fetch_chdir($project);
    my $version = project_config($project, 'version');
    if (my $tag_gpg_id = gpg_id(project_config($project, 'tag_gpg_id'))) {
        my $id = git_tag_sign_id($project, $git_hash) ||
                exit_error "$git_hash is not a signed tag";
        if (!valid_id($id, $tag_gpg_id)) {
            exit_error "Tag $git_hash is not signed with a valid key";
        }
        print "Tag $git_hash is signed with key $id\n";
    }
    if (my $commit_gpg_id = gpg_id(project_config($project, 'commit_gpg_id'))) {
        my $id = git_commit_sign_id($project, $git_hash) ||
                exit_error "$git_hash is not a signed commit";
        if (!valid_id($id, $commit_gpg_id)) {
            exit_error "Commit $git_hash is not signed with a valid key";
        }
        print "Commit $git_hash is signed with key $id\n";
    }
    my $tar_file = "$project-$version.tar";
    system('git', 'archive', "--prefix=$project-$version/",
        "--output=$dest_dir/$tar_file", $git_hash) == 0
        || exit_error 'Error running git archive.';
    my %compress = (
        xz  => ['xz', '-f'],
        gz  => ['gzip', '-f'],
        bz2 => ['bzip2', '-f'],
    );
    if (my $c = project_config($project, 'compress_tar')) {
        if (!defined $compress{$c}) {
            exit_error "Unknow compression $c";
        }
        system(@{$compress{$c}}, "$dest_dir/$tar_file") == 0
                || exit_error "Error compressing $tar_file with $compress{$c}->[0]";
        $tar_file .= ".$c";
    }
    my $timestamp = project_config($project, 'timestamp');
    utime $timestamp, $timestamp, "$dest_dir/$tar_file" if $timestamp;
    print "Created $dest_dir/$tar_file\n";
    chdir($old_cwd);
    return $tar_file;
}

sub process_template {
    my ($project, $tmpl, $dest_dir) = @_;
    $dest_dir //= create_dir(path(project_config($project, 'output_dir')));
    my $distribution = get_distribution($project);
    my $projects_dir = path(project_config($project, 'projects_dir'));
    my $template = Template->new(
        ENCODING        => 'utf8',
        INCLUDE_PATH    => "$projects_dir/$project:$projects_dir/common",
    );
    my $vars = {
        config     => $config,
        project    => $project,
        p          => $config->{projects}{$project},
        d          => $config->{distributions}{$distribution},
        c          => sub { project_config($project, @_) },
        dest_dir   => $dest_dir,
        exit_error => \&exit_error,
        exec       => sub { execute($project, $_[0]) },
        path       => \&path,
        tmpl       => sub { process_template($project, $_[0], $dest_dir) },
        shell_quote => \&shell_quote,
        versioncmp  => \&versioncmp,
    };
    my $output;
    $template->process(\$tmpl, $vars, \$output, binmode => ':utf8')
                    || exit_error "Template Error:\n" . $template->error;
    return $output;
}

sub rpmspec {
    my ($project, $dest_dir) = @_;
    $dest_dir //= create_dir(path(project_config($project, 'output_dir')));
    valid_project($project);
    my $git_hash = project_config($project, 'git_hash');
    my $timestamp = project_config($project, 'timestamp');
    my $rpmspec = project_config($project, 'rpmspec')
                || exit_error "Undefined config for rpmspec";
    write_file("$dest_dir/$project.spec", $rpmspec);
    utime $timestamp, $timestamp, "$dest_dir/$project.spec" if $timestamp;
}

sub projectslist {
    keys %{$config->{projects}};
}

sub copy_files {
    my ($project, $dest_dir) = @_;
    my @r;
    my $copy_files = project_config($project, 'copy_files');
    return unless $copy_files;
    my $proj_dir = path(project_config($project, 'projects_dir'));
    my $src_dir = "$proj_dir/$project";
    foreach my $file (@$copy_files) {
        copy("$src_dir/$file", "$dest_dir/$file");
        push @r, $file;
    }
    return @r;
}

sub rpmbuild {
    my ($project, $action, $dest_dir) = @_;
    $dest_dir //= create_dir(path(project_config($project, 'output_dir')));
    valid_project($project);
    my $tmpdir = File::Temp->newdir;
    maketar($project, $tmpdir->dirname);
    copy_files($project, $tmpdir->dirname);
    rpmspec($project, $tmpdir->dirname);
    my $options = {
        rpmbuild_action => $action,
        output_dir      => $dest_dir,
        rpmbuild_srcdir => $tmpdir->dirname,
    };
    my $rpmbuild = project_config($project, 'rpmbuild', $options);
    run_script($rpmbuild, sub { system(@_) }) == 0
                || exit_error "Error running rpmbuild";
}

sub build_run {
    my ($project, $script_name, $dest_dir) = @_;
    my $error;
    $dest_dir //= create_dir(path(project_config($project, 'output_dir')));
    valid_project($project);
    my $tmpdir = File::Temp->newdir;
    my $tarfile = maketar($project, $tmpdir->dirname);
    my @cfiles = copy_files($project, $tmpdir->dirname);
    my ($remote_tmp_src, $remote_tmp_dst, $build_script);
    if (project_config($project, "remote/$script_name")) {
        foreach my $remote_tmp ($remote_tmp_src, $remote_tmp_dst) {
            my $cmd = project_config($project, "remote/$script_name/exec", {
                    exec_cmd => project_config($project,
                        "remote/$script_name/mktmpdir") || 'mktemp -d',
                });
            my ($stdout, $stderr, $success, $exit_code)
                = run_script($cmd, \&capture_exec);
            if (!$success) {
                $error = "Error connecting to remote";
                goto EXIT;
            }
            $remote_tmp = (split("\n", $stdout))[0];
        }
        $build_script = project_config($project, $script_name, {
                output_dir => $remote_tmp_dst,
            });
    } else {
        $build_script = project_config($project, $script_name);
    }
    if (!$build_script) {
        $error = "Missing $script_name config";
        goto EXIT;
    }
    write_file("$tmpdir/build", $build_script);
    my $old_cwd = getcwd;
    chdir $tmpdir->dirname;
    chmod 0700, 'build';
    my $res;
    if ($remote_tmp_src && $remote_tmp_dst) {
        foreach my $file ($tarfile, 'build', @cfiles) {
            my $cmd = project_config($project, "remote/$script_name/put", {
                    put_src => "$tmpdir/$file",
                    put_dst => $remote_tmp_src,
                });
            if (run_script($cmd, sub { system(@_) }) != 0) {
                $error = "Error uploading $file";
                goto EXIT;
            }
        }
        my $cmd = project_config($project, "remote/$script_name/exec", {
                exec_cmd => "cd $remote_tmp_src; ./build",
            });
        if (run_script($cmd, sub { system(@_) }) != 0) {
            $error = "Error running $script_name";
            goto EXIT;
        }
        $cmd = project_config($project, "remote/$script_name/get", {
                get_src => "$remote_tmp_dst/*",
                get_dst => $dest_dir,
            });
        if (run_script($cmd, sub { system(@_) }) != 0) {
            $error = "Error downloading build result";
        }
        run_script(project_config($project, "remote/$script_name/exec", {
                exec_cmd => "rm -Rf $remote_tmp_src $remote_tmp_dst",
            }), \&capture_exec);
    } else {
        if (system("$tmpdir/build") != 0) {
            $error = "Error running $script_name";
        }
    }
    EXIT:
    chdir $old_cwd;
    exit_error $error if $error;
}

1;

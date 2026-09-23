# Copyright © 2022 Felix Lechner <felix.lechner@lease-up.com>
#
# based on a shell script library by John Goerzen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Debian::Debhelper::Buildsystem::Haskell::Recipes;

use v5.20;
use warnings;
use utf8;

use Exporter qw(import);

our @EXPORT_OK;

BEGIN {

    @EXPORT_OK = qw(
      run_quiet
      run
      installable_hc
      installable_type
      installable_config_shipper
      source_hc
      hc_libdir
      hc_pkgdir
      hc_haddock
      hc_docdir
      hc_htmldir
      hashed_dependency
      ghc_pkg_command
      load_ghc_database
      own_cabal_prerequisites
      hashed_id_to_virtual_installable
      config_to_package_id
      config_to_package_name_version
      is_package_private
      init_hs_env
      clean_recipe
      make_setup_recipe
      configure_recipe
      build_recipe
      check_recipe
      haddock_recipe
      install_recipe
    );
}

use Carp qw(croak);
use Const::Fast;
use Date::Parse qw(str2time);
use Debian::Debhelper::Dh_Lib qw(doit);
use File::Temp;
use IPC::Run3;
use List::SomeUtils qw(uniq any first_value);
use Path::Tiny;
use Text::ParseWords qw(shellwords);
use Unicode::UTF8 qw(encode_utf8 decode_utf8);

const my $EMPTY => q{};
const my $SPACE => q{ };
const my $DOUBLE_QUOTE => q{"};
const my $NEWLINE => qq{\n};

const my $WAIT_STATUS_SHIFT => 8;

const my $CABAL_VERSION_IMPLYING_SIMPLE_BUILDS => 2.2;

=head1 NAME

Debian::Debhelper::Buildsystem::Haskell::Recipes -- Recipes for the Haskell build system in Debhelper

=head1 SYNOPSIS

 Debian::Debhelper::Buildsystem::Haskell::Recipes;

=head1 DESCRIPTION

A library with recipes for the Haskell build system in Debhelper.

=head1 SUBROUTINES

=over 4

=item run_quiet

=cut

sub run_quiet {
    my (@command) = @_;

    my @command_bytes = map { encode_utf8($_) } @command;

    my $stdout_bytes;
    my $stderr_bytes;
    run3(\@command_bytes, \undef, \$stdout_bytes, \$stderr_bytes);

    my $wait_status = $?;
    my $exitcode = ($wait_status >> $WAIT_STATUS_SHIFT);

    # already in UTF-8
    die encode_utf8("Non-zero exit code $exitcode.")
      . $NEWLINE
      . $stdout_bytes
      . $stderr_bytes
      if $exitcode;

    my $output = decode_utf8($stdout_bytes // $EMPTY);
    chomp $output;

    return $output;
}

=item run

=cut

sub run {
    my (@command) = @_;

    my @filtered = grep { length } @command;

    say {*STDERR} encode_utf8("Running @filtered")
      if !$ENV{DH_QUIET} || $ENV{DH_VERBOSE};

    my $output = run_quiet(@filtered);

    say {*STDERR} encode_utf8($output)
      if length $output
      && (!$ENV{DH_QUIET} || $ENV{DH_VERBOSE});

    return $output;
}

=item installable_hc

=cut

sub installable_hc {
    my ($installable) = @_;

    return 'ghc'
      if $installable =~ m{^ ghc (:? -prof )? $};

    # get compiler from lib prefix, if possible
    if ($installable =~ m{^ lib ( [^-]+ ) - }x) {

        my $compiler = $1;

        return $compiler;
    }

    return $EMPTY;
}

=item installable_type

=cut

sub installable_type {
    my ($installable) = @_;

    return 'dev'
      if $installable eq 'ghc';

    return 'prof'
      if $installable eq 'ghc-prof';

    # look at suffix
    if ($installable =~ m{^ lib .* - ( [^-]+) $}x) {

        my $suffix = $1;

        return $suffix;
    }

    return $EMPTY;
}

=item installable_config_shipper

=cut

sub installable_config_shipper {
    my ($installable) = @_;

    if ($installable =~ m{^ ( lib .* ) - ( [^-]+) $}x) {

        my $prefix = $1;
        my $type = $2;

        return $installable
            if $type eq 'dev';

        return "$prefix-dev";
    }

    return $EMPTY;
}

=item source_hc

=cut

sub source_hc {
    my () = @_;

    # should be in UTF-8
    my $package_list = run('dh_listpackages');
    chomp $package_list;

    my @installables = split($SPACE, $package_list);

    my @compilers
      = uniq grep { length } map { installable_hc($_) } @installables;

    croak encode_utf8(
        'Multiple compilers not supported: ' . join($SPACE, (sort @compilers)))
      if @compilers > 1;

    return $compilers[0]
      if @compilers;

    return $EMPTY;
}

=item hc_libdir

=cut

sub hc_libdir {
    my ($compiler) = @_;

    croak encode_utf8('No Haskell compiler.')
      unless length $compiler;

    return 'usr/lib/haskell-packages/ghc/lib'
      if $compiler eq 'ghc';

    return 'usr/lib/ghcjs/.cabal/lib'
      if $compiler eq 'ghcjs';

    croak encode_utf8("Don't know libdir for $compiler");
}

=item hc_pkgdir

=cut

sub hc_pkgdir {
    my ($compiler) = @_;

    croak encode_utf8('No Haskell compiler.')
      unless length $compiler;

    return 'var/lib/ghc/package.conf.d'
      if $compiler eq 'ghc';

    if ($compiler eq 'ghcjs') {

        my $cpu = run(qw{ghc -ignore-dot-ghci -e}, 'putStr System.Info.arch');
        my $os = run(qw{ghc -ignore-dot-ghci -e}, 'putStr System.Info.os');
        my $ghcjs_version = run(qw{ghcjs --numeric-ghcjs-version});
        my $ghcjs_ghc_version = run(qw{ghcjs --numeric-ghc-version});

        my $quadruplet = "$cpu-$os-$ghcjs_version-$ghcjs_ghc_version";

        return "usr/lib/ghcjs/.ghcjs/$quadruplet/ghcjs/package.conf.d";
    }

    croak encode_utf8("Don't know pkgdir for $compiler");
}

=item hc_prefix

=cut

sub hc_prefix {
    my ($compiler) = @_;

    croak encode_utf8('No Haskell compiler.')
      unless length $compiler;

    return 'usr'
      if $compiler eq 'ghc';

    return 'usr/lib/ghcjs'
      if $compiler eq 'ghcjs';

    croak encode_utf8("Don't know prefix for $compiler");
}

=item hc_haddock

=cut

sub hc_haddock {
    my ($compiler) = @_;

    croak encode_utf8('No Haskell compiler.')
      unless length $compiler;

    return 'haddock'
      if $compiler eq 'ghc';

    return 'haddock-ghcjs'
      if $compiler eq 'ghcjs';

    croak encode_utf8("Don't know haddock command for $compiler");
}

=item hc_docdir

=cut

sub hc_docdir {
    my ($compiler, $hackage_name, $hackage_version) = @_;

    croak encode_utf8('No Haskell compiler.')
      unless length $compiler;

    return "usr/lib/$compiler-doc/haddock/$hackage_name-$hackage_version/";
}

=item hc_htmldir

=cut

sub hc_htmldir {
    my ($compiler, $hackage_name) = @_;

    croak encode_utf8('No Haskell compiler.')
      unless length $compiler;

    return "usr/share/doc/lib$compiler-$hackage_name-doc/html/";
}

=item hashed_dependency

=cut

sub hashed_dependency {
    my ($compiler, $type, $hashed_id) = @_;

    my $ghc_pkg = ghc_pkg_command();

    # different order of arguments
    my $installable
      = hashed_id_to_virtual_installable($compiler, $hashed_id, $type,
        $ghc_pkg, '--global');

    return $installable;
}

=item ghc_pkg_command

=cut

sub ghc_pkg_command {
    my () = @_;

    my $inplace_ghc_pkg = 'inplace/bin/ghc-pkg';
    my $stage2_ghc_pkg = '_build/stage1/bin/ghc-pkg';

    # building ghc; use the new ghc-pkg
    # (this is the old location when using the make build system)
    return $inplace_ghc_pkg
      if -x $inplace_ghc_pkg;

    # (this is the new location when using the Hadrian build system)
    return $stage2_ghc_pkg
      if -x $stage2_ghc_pkg;

    return 'ghc-pkg';
}

=item own_cabal_prerequisites

=cut

sub own_cabal_prerequisites {
    my ($compiler, $tmp_db) = @_;

    croak encode_utf8('No Setup.hs executable named.')
      unless length $ENV{DEB_SETUP_BIN_NAME};

    my $tmp = File::Temp->new();
    my %options = (
        stdout => $tmp->filename,
        update_env => { LC_ALL => 'C.UTF-8'},
    );
    doit(\%options, $ENV{DEB_SETUP_BIN_NAME},
        'register', "--builddir=dist-$compiler",
        qw{--gen-pkg-config --verbose=verbose+nowrap});
    my $output = do { local $/; <$tmp> };
    say $output if !$ENV{DH_QUIET};

    my @hashed_ids;
    if ($output
        =~ m{^Creating \s package \s registration \s (file|directory): \s+ (\S+) $}mx) {

        my $pkg_config = $2;

        if (-d $pkg_config) {
            # If the package registration is a directory, load all .conf files
            my @pkg_configs = glob("$pkg_config/*");
            my $ghc_pkg = ghc_pkg_command();
            load_ghc_database($ghc_pkg, $tmp_db, @pkg_configs);

            # Gather all the depends from all the libraries
            my $locals
                = run_quiet($ghc_pkg, '--package-db', $tmp_db,
                            '--simple-output', '--show-unit-ids', 'list');
            my @local_pkgs = uniq(split($SPACE, $locals // $EMPTY));
            for my $pkg (@local_pkgs) {
                my $depends = run($ghc_pkg, '--package-db', $tmp_db, 'field',
                                  '--unit-id', '--simple-output', $pkg,
                                  'depends');
                push(@hashed_ids, split($SPACE, $depends // $EMPTY));
            }

            # Filter out those depends that are internal
            @hashed_ids = uniq(@hashed_ids);
            my %local_hash = map { $_ => 1 } @local_pkgs;
            @hashed_ids = grep { !$local_hash{$_} } @hashed_ids;

            run(qw{rm -rf}, $pkg_config);

            return @hashed_ids;
        }

        my $ghc_pkg = ghc_pkg_command();
        load_ghc_database($ghc_pkg, $tmp_db, $pkg_config);

        my $name = path($pkg_config)->basename(qr{ [.]conf $}x);
        my $depends
          = run($ghc_pkg, '--package-db', $tmp_db, qw{--simple-output field},
            $name, 'depends');

        push(@hashed_ids, split($SPACE, $depends // $EMPTY));

        run(qw{rm -rf}, $pkg_config);

    } else {
        warn encode_utf8('Cannot generate package registration.');
    }

    return @hashed_ids;
}

=item load_ghc_database

=cut

sub load_ghc_database {
    my ($ghc_pkg, $tmp_db, @configs) = @_;

    croak encode_utf8('No ghc-pkg executable')
      unless length $ghc_pkg;

    croak encode_utf8('No folder for temporary GHC package data')
      unless length $tmp_db;

    path($tmp_db)->mkpath
      unless -e $tmp_db;

    run('cp', @configs, $tmp_db)
      if @configs;

    # Silence GHC 8.4's warning
    # "ignoring (possibly broken) abi-depends field for packages"
    # see also https://ghc.haskell.org/trac/ghc/ticket/14381
    run($ghc_pkg, '--package-db', $tmp_db, 'recache');

    return;
}

=item hashed_id_to_virtual_installable

=cut

sub hashed_id_to_virtual_installable {
    my ($compiler, $hashed_id, $type, @command) = @_;

    croak encode_utf8('No Haskell compiler.')
      unless length $compiler;

    my $name;
    my $version;
    my $long_abi;

    if (@command) {

        $name = run(@command, qw{--simple-output --unit-id field},
            $hashed_id, 'name');
        $version = run(@command, qw{--simple-output --unit-id field},
            $hashed_id, 'version');
        $long_abi = run(@command, qw{--simple-output --unit-id field},
            $hashed_id, 'abi');

    } else {

        # no usable ghc-pkg; parse package id
        my $lowercase = lc $hashed_id;

        ($name, $version, $long_abi)
          = ($lowercase =~ m{^ ([a-z0-9-]+) - ([0-9.]+) - (\S{32}) $}x);
    }

    # retain only the first five hex digits from abi out of 32
    my ($short_abi) = ($long_abi =~ m{^ (\S{5}) }x);

    my $virtual = lc "lib$compiler-$name-$type-$version-$short_abi";

    return $virtual;
}

=item config_to_package_id

=cut

sub config_to_package_id {
    my ($config, $ghc_pkg, $package_db) = @_;

    my $name = path($config)->basename(qr { [.]conf $}x);

    $name =~ m/^([^ ]*?)-(\d[\d.]*)(-\S+)?$/;
    $name = "$1-$2";

    my $package_id = run($ghc_pkg, '--package-db', $package_db,
        qw{--simple-output field}, $name, 'id');

    return $package_id;
}

=item config_to_package_name_version

=cut

sub config_to_package_name_version {
    my ($config) = @_;

    my $cabal_contents = path($config)->slurp_utf8;

    die encode_utf8('Cannot get package name from config file')
        unless $cabal_contents =~ /^ name \s* : \s* (\S*) \s* $/imx;

    my $package_name = $1;

    die encode_utf8('Cannot get package version from config file')
        unless $cabal_contents =~ /^ version \s* : \s* (\S*) \s* $/imx;

    my $package_version = $1;

    return ($package_name, $package_version);
}

=item is_pkg_internal

=cut

sub is_package_private {
    my ($package_id, $ghc_pkg, $package_db) = @_;

    my $visibility
        = run_quiet($ghc_pkg, '--package-db', $package_db, 'field',
                    '--unit-id', '--simple-output', $package_id, 'visibility');
    return 1
        if $visibility eq 'private';

    return 0;
}

=item init_hs_env

=cut

sub init_hs_env {
    my %params = (
        parse_cabal => 1,
        @_
    );

    $ENV{DEB_DEFAULT_COMPILER} //= 'ghc';

    $ENV{DEB_GHC_DATABASE} = 'debian/tmp-db';

    if ($params{parse_cabal}) {
        my @cabal_candidates = glob('*.cabal');

        die encode_utf8('No cabal file found')
            unless @cabal_candidates;

        die encode_utf8('More than one cabal file')
            if @cabal_candidates > 1;

        my $cabal_path = $cabal_candidates[0];
        my $cabal_contents = path($cabal_path)->slurp_utf8;

        die encode_utf8('Cannot get package name from cabal file')
            unless $cabal_contents =~ /^ name \s* : \s* (\S*) \s* $/imx;

        my $package_name = lc $1;

        $ENV{CABAL_PACKAGE} //= $package_name;

        die encode_utf8('Cannot get package version from cabal file')
            unless $cabal_contents =~ /^ version \s* : \s* (\S*) \s* $/imx;

        my $package_version = $1;

        $ENV{CABAL_VERSION} = $package_version;
    }

    $ENV{DEB_ENABLE_TESTS} //= 'no';
    $ENV{DEB_ENABLE_HOOGLE} //= 'yes';

    $ENV{DEB_SETUP_BIN_NAME} //= 'debian/hlibrary.setup';

    return;
}

=item clean_recipe

=cut

sub clean_recipe {
    my () = @_;

    croak encode_utf8('No Setup.hs executable named.')
      unless length $ENV{DEB_SETUP_BIN_NAME};

    run($ENV{DEB_SETUP_BIN_NAME}, qw{clean})
      if -x $ENV{DEB_SETUP_BIN_NAME};

    run(qw{rm -rf dist dist-ghc dist-ghcjs dist-hugs debian/tmp-setup-hs});
    run(qw{rm -f}, $ENV{DEB_SETUP_BIN_NAME});
    run(qw{rm -f Setup.hi Setup.ho Setup.o});
    run(qw{rm -f}, glob('.*config*'));

    return;
}

=item make_setup_recipe

=cut

sub make_setup_recipe {
    my () = @_;

    croak encode_utf8('No Setup.hs executable named.')
      unless length $ENV{DEB_SETUP_BIN_NAME};

    my $shipped_setup = first_value { -e } qw{Setup.lhs Setup.hs};

    if (length $shipped_setup) {

        run(qw{ghc --make}, $shipped_setup, '-o',$ENV{DEB_SETUP_BIN_NAME});
        return;
    }

# Having a Setup.hs is considered good practice, but there are a few
# Haskell packages that don't, since cabal does not use it for build types
# other than 'Custom'. Find out the build type and use the corresponding
# standardized Setup.hs file. For more information, see
# https://www.haskell.org/cabal/users-guide/developing-packages.html#pkg-field-build-type

    my $cabal_path = (glob("*.cabal"))[0];
    my $cabal_contents = path($cabal_path)->slurp_utf8;

    die encode_utf8("No cabal-version in $cabal_path")
      unless $cabal_contents
      =~ m{^ cabal-version: (?: \s+ [<>=]+ )? \s+ (\S+) \s* $}mix;

    my $cabal_version = $1;

    my $build_type;

    if ($cabal_contents =~ m{^ build-type: \s+ (\w+) \s* }mix) {
        $build_type = $1;
    }

  # https://cabal.readthedocs.io/en/3.4/cabal-package.html#pkg-field-build-type
    my $default_build_type = 'Simple';
    $default_build_type = 'Custom'
      if $cabal_version < $CABAL_VERSION_IMPLYING_SIMPLE_BUILDS
      || $cabal_contents =~ m{^ custom-setup \s+ }mi;

    $build_type //= $default_build_type;

    my $stock_setup = "/usr/share/haskell-devscripts/Setup-$build_type.hs";
    die encode_utf8("Could not find a suitable Setup.hs file for $build_type")
      unless -e $stock_setup;

    run(
        qw{ghc --make}, $stock_setup, '-o',
        $ENV{DEB_SETUP_BIN_NAME},
        qw{-outputdir debian/tmp-setup-hs}
    );

    return;
}

=item configure_recipe

=cut

sub configure_recipe {
    my () = @_;

    croak encode_utf8('No Setup.hs executable named.')
      unless length $ENV{DEB_SETUP_BIN_NAME};

    # deleted when out of scope
    my $time_reference = Path::Tiny->tempfile;
    $time_reference->touch(str2time('1975-01-01', 'UTC'));

    # dak does not like file timestamps older than 1975
    # new tarballs from Hackage have files with mtimes at the
    # beginning of the epoch, so set old mtimes to 1998
    run(
        qw{find . ! -newer},
        $time_reference->stringify,
        qw{-exec touch -d},
        '1998-01-01 UTC',
        qw{{} ; }
    );

    my $compiler = source_hc() || $ENV{DEB_DEFAULT_COMPILER};
    die encode_utf8('No Haskell compiler.')
      unless length $compiler;

    my $package_list = run('dh_listpackages');
    chomp $package_list;

    my @installables = split($SPACE, $package_list);
    my @types = map { installable_type($_) } @installables;

    my $profiling;
    $profiling = '--enable-library-profiling'
      if any { $_ eq 'prof' } @types;

    my $ldflags_line = run(qw{dpkg-buildflags --get LDFLAGS});
    my @ldflags = split($SPACE, $ldflags_line);
    my @ghc_options = map { "--ghc-option=-optl$_" } @ldflags;

    my $pkgdir = hc_pkgdir($compiler);
    my $prefix = hc_prefix($compiler);
    my $libdir = hc_libdir($compiler);
    my $docdir
      = hc_docdir($compiler, $ENV{CABAL_PACKAGE}, $ENV{CABAL_VERSION});
    my $htmldir = hc_htmldir($compiler, $ENV{CABAL_PACKAGE});

    # the versioned form DEB_SETUP_GHC6_CONFIGURE_ARGS should perhaps be
    # abandoned in favor of the unversioned DEB_SETUP_GHC_CONFIGURE_ARGS

    run(
        $ENV{DEB_SETUP_BIN_NAME},
        'configure',
        "--$compiler",
        '-v2',
        "--package-db=/$pkgdir",
        "--prefix=/$prefix",
        "--libdir=/$libdir",
        '--libexecdir=/usr/lib',
        "--builddir=dist-$compiler",
        @ghc_options,
        "--haddockdir=/$docdir",
        "--datasubdir=$ENV{CABAL_PACKAGE}",
        "--htmldir=/$htmldir",
        $profiling,
        $ENV{NO_GHCI_FLAG},
        shellwords($ENV{DEB_SETUP_GHC6_CONFIGURE_ARGS} // $EMPTY),
        shellwords($ENV{DEB_SETUP_GHC_CONFIGURE_ARGS} // $EMPTY),
        split($SPACE, $ENV{OPTIMIZATION} // $EMPTY),
        split($SPACE, $ENV{TESTS} // $EMPTY));

    return;
}

=item build_recipe

=cut

sub build_recipe {
    my %params = (
        parallel => 0,
        @_
    );

    croak encode_utf8('No Setup.hs executable named.')
      unless length $ENV{DEB_SETUP_BIN_NAME};

    my $compiler = source_hc() || $ENV{DEB_DEFAULT_COMPILER};
    die encode_utf8('No Haskell compiler.')
      unless length $compiler;

    my @args = ($ENV{DEB_SETUP_BIN_NAME}, 'build', "--builddir=dist-$compiler");
    if ($params{parallel}) {
        push(@args, "--jobs=$params{parallel}");
    }
    doit(@args);

    return;
}

=item check_recipe

=cut

sub check_recipe {
    my () = @_;

    croak encode_utf8('No Setup.hs executable named.')
      unless length $ENV{DEB_SETUP_BIN_NAME};

    if ($ENV{DEB_ENABLE_TESTS} ne 'yes') {

        say encode_utf8(
'DEB_ENABLE_TESTS not set to yes, not running any build-time tests.'
        );
        return;
    }

    if ($ENV{DEB_BUILD_OPTIONS} =~ m{ nocheck }x) {

        say encode_utf8(
'DEB_BUILD_OPTIONS contains nocheck, not running any build-time tests.'
        );
        return;
    }

    my $compiler = source_hc() || $ENV{DEB_DEFAULT_COMPILER};
    die encode_utf8('No Haskell compiler.')
      unless length $compiler;

    doit($ENV{DEB_SETUP_BIN_NAME},
        'test', "--builddir=dist-$compiler", '--show-details=direct');

    return;
}

=item haddock_recipe

=cut

sub haddock_recipe {
    my () = @_;

    croak encode_utf8('No Setup.hs executable named.')
      unless length $ENV{DEB_SETUP_BIN_NAME};

    my $compiler = source_hc() || $ENV{DEB_DEFAULT_COMPILER};
    die encode_utf8('No Haskell compiler.')
      unless length $compiler;

    my $haddock = hc_haddock($compiler);

    return
      unless -x "/usr/bin/$haddock";

    run(
        $ENV{DEB_SETUP_BIN_NAME},
        'haddock',
        "--builddir=dist-$compiler",
        "--with-haddock=/usr/bin/$haddock",
        "--with-ghc=$compiler",
        '--verbose=2',
        split($SPACE, $ENV{DEB_HADDOCK_OPTS} // $EMPTY));

    return;
}

=item install_recipe

=cut

sub install_recipe {
    my ($destination) = @_;

    croak encode_utf8('No Setup.hs executable named.')
      unless length $ENV{DEB_SETUP_BIN_NAME};

    my $compiler = source_hc() || $ENV{DEB_DEFAULT_COMPILER};
    die encode_utf8('No Haskell compiler.')
      unless length $compiler;

    run($ENV{DEB_SETUP_BIN_NAME},
        'copy', "--builddir=dist-$compiler", "--destdir=$destination");

    return;
}

=head1 AUTHOR

Written by Felix Lechner <felix.lechner@lease-up.com> for Haskell Devscripts.
Based on Dh_Haskell.sh.

=head1 SEE ALSO

Debian::Debhelper::Buildsystem::haskell(3pm)

=cut

1;

# Local Variables:
# indent-tabs-mode: nil
# cperl-indent-level: 4
# End:
# vim: syntax=perl sw=4 sts=4 sr et

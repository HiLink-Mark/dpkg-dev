# Copyright © 2008-2011 Raphaël Hertzog <hertzog@debian.org>
# Copyright © 2008-2015 Guillem Jover <guillem@debian.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

package Dpkg::Source::Package::V2;

use strict;
use warnings;

our $VERSION = '0.01';

use POSIX qw(:errno_h);
use List::Util qw(first);
use Cwd;
use File::Basename;
use File::Temp qw(tempfile tempdir);
use File::Path qw(make_path);
use File::Spec;
use File::Find;
use File::Copy;

use Dpkg::Gettext;
use Dpkg::ErrorHandling;
use Dpkg::File;
use Dpkg::Path qw(find_command);
use Dpkg::Compression;
use Dpkg::Source::Archive;
use Dpkg::Source::Patch;
use Dpkg::Exit qw(push_exit_handler pop_exit_handler);
use Dpkg::Source::Functions qw(erasedir is_binary fs_time);
use Dpkg::Vendor qw(run_vendor_hook);
use Dpkg::Control;
use Dpkg::Changelog::Parse;

use parent qw(Dpkg::Source::Package);

our $CURRENT_MINOR_VERSION = '0';

sub init_options {
    my $self = shift;
    $self->SUPER::init_options();
    $self->{options}{include_removal} //= 0;
    $self->{options}{include_timestamp} //= 0;
    $self->{options}{include_binaries} //= 0;
    $self->{options}{preparation} //= 1;
    $self->{options}{skip_patches} //= 0;
    $self->{options}{unapply_patches} //= 'auto';
    $self->{options}{skip_debianization} //= 0;
    $self->{options}{create_empty_orig} //= 0;
    $self->{options}{auto_commit} //= 0;
    $self->{options}{ignore_bad_version} //= 0;
}

my @module_cmdline = (
    {
        name => '--include-removal',
        help => N_('include removed files in the patch'),
        when => 'build',
    }, {
        name => '--include-timestamp',
        help => N_('include timestamp in the patch'),
        when => 'build',
    }, {
        name => '--include-binaries',
        help => N_('include binary files in the tarball'),
        when => 'build',
    }, {
        name => '--no-preparation',
        help => N_('do not prepare build tree by applying patches'),
        when => 'build',
    }, {
        name => '--no-unapply-patches',
        help => N_('do not unapply patches if previously applied'),
        when => 'build',
    }, {
        name => '--unapply-patches',
        help => N_('unapply patches if previously applied (default)'),
        when => 'build',
    }, {
        name => '--create-empty-orig',
        help => N_('create an empty original tarball if missing'),
        when => 'build',
    }, {
        name => '--abort-on-upstream-changes',
        help => N_('abort if generated diff has upstream files changes'),
        when => 'build',
    }, {
        name => '--auto-commit',
        help => N_('record generated patches, instead of aborting'),
        when => 'build',
    }, {
        name => '--skip-debianization',
        help => N_('do not extract debian tarball into upstream sources'),
        when => 'extract',
    }, {
        name => '--skip-patches',
        help => N_('do not apply patches at the end of the extraction'),
        when => 'extract',
    }
);

sub describe_cmdline_options {
    return @module_cmdline;
}

sub parse_cmdline_option {
    my ($self, $opt) = @_;
    if ($opt eq '--include-removal') {
        $self->{options}{include_removal} = 1;
        return 1;
    } elsif ($opt eq '--include-timestamp') {
        $self->{options}{include_timestamp} = 1;
        return 1;
    } elsif ($opt eq '--include-binaries') {
        $self->{options}{include_binaries} = 1;
        return 1;
    } elsif ($opt eq '--no-preparation') {
        $self->{options}{preparation} = 0;
        return 1;
    } elsif ($opt eq '--skip-patches') {
        $self->{options}{skip_patches} = 1;
        return 1;
    } elsif ($opt eq '--unapply-patches') {
        $self->{options}{unapply_patches} = 'yes';
        return 1;
    } elsif ($opt eq '--no-unapply-patches') {
        $self->{options}{unapply_patches} = 'no';
        return 1;
    } elsif ($opt eq '--skip-debianization') {
        $self->{options}{skip_debianization} = 1;
        return 1;
    } elsif ($opt eq '--create-empty-orig') {
        $self->{options}{create_empty_orig} = 1;
        return 1;
    } elsif ($opt eq '--abort-on-upstream-changes') {
        $self->{options}{auto_commit} = 0;
        return 1;
    } elsif ($opt eq '--auto-commit') {
        $self->{options}{auto_commit} = 1;
        return 1;
    } elsif ($opt eq '--ignore-bad-version') {
        $self->{options}{ignore_bad_version} = 1;
        return 1;
    }
    return 0;
}

sub do_extract {
    my ($self, $newdirectory) = @_;
    my $fields = $self->{fields};

    my $dscdir = $self->{basedir};

    my $basename = $self->get_basename();
    my $basenamerev = $self->get_basename(1);

    my ($tarfile, $debianfile, %addonfile, %seen);
    my ($tarsign, %addonsign);
    my $re_ext = compression_get_file_extension_regex();
    foreach my $file ($self->get_files()) {
        my $uncompressed = $file;
        $uncompressed =~ s/\.$re_ext$/.*/;
        $uncompressed =~ s/\.$re_ext\.asc$/.*.asc/;
        error(g_('duplicate files in %s source package: %s'), 'v2.0',
              $uncompressed) if $seen{$uncompressed};
        $seen{$uncompressed} = 1;
        if ($file =~ /^\Q$basename\E\.orig\.tar\.$re_ext$/) {
            $tarfile = $file;
        } elsif ($file =~ /^\Q$basename\E\.orig\.tar\.$re_ext\.asc$/) {
            $tarsign = $file;
        } elsif ($file =~ /^\Q$basename\E\.orig-([[:alnum:]-]+)\.tar\.$re_ext$/) {
            $addonfile{$1} = $file;
        } elsif ($file =~ /^\Q$basename\E\.orig-([[:alnum:]-]+)\.tar\.$re_ext\.asc$/) {
            $addonsign{$1} = $file;
        } elsif ($file =~ /^\Q$basenamerev\E\.debian\.tar\.$re_ext$/) {
            $debianfile = $file;
        } else {
            error(g_('unrecognized file for a %s source package: %s'),
            'v2.0', $file);
        }
    }

    unless ($tarfile and $debianfile) {
        error(g_('missing orig.tar or debian.tar file in v2.0 source package'));
    }
    if ($tarsign and $tarfile ne substr $tarsign, 0, -4) {
        error(g_('mismatched orig.tar %s for signature %s in source package'),
              $tarfile, $tarsign);
    }
    foreach my $name (keys %addonsign) {
        error(g_('missing addon orig.tar for signature %s in source package'),
              $addonsign{$name})
            if not exists $addonfile{$name};
        error(g_('mismatched addon orig.tar %s for signature %s in source package'),
              $addonfile{$name}, $addonsign{$name})
            if $addonfile{$name} ne substr $addonsign{$name}, 0, -4;
    }

    erasedir($newdirectory);

    # Extract main tarball
    info(g_('unpacking %s'), $tarfile);
    my $tar = Dpkg::Source::Archive->new(filename => "$dscdir$tarfile");
    $tar->extract($newdirectory, no_fixperms => 1,
                  options => [ '--anchored', '--no-wildcards-match-slash',
                               '--exclude', '*/.pc', '--exclude', '.pc' ]);
    # The .pc exclusion is only needed for 3.0 (quilt) and to avoid
    # having an upstream tarball provide a directory with symlinks
    # that would be blindly followed when applying the patches

    # Extract additional orig tarballs
    foreach my $subdir (sort keys %addonfile) {
        my $file = $addonfile{$subdir};
        info(g_('unpacking %s'), $file);

        # If the pathname is an empty directory, just silently remove it, as
        # it might be part of a git repository, as a submodule for example.
        rmdir "$newdirectory/$subdir";
        if (-e "$newdirectory/$subdir") {
            warning(g_("required removal of '%s' installed by original tarball"),
                    $subdir);
            erasedir("$newdirectory/$subdir");
        }
        $tar = Dpkg::Source::Archive->new(filename => "$dscdir$file");
        $tar->extract("$newdirectory/$subdir", no_fixperms => 1);
    }

    # Stop here if debianization is not wanted
    return if $self->{options}{skip_debianization};

    # Extract debian tarball after removing the debian directory
    info(g_('unpacking %s'), $debianfile);
    erasedir("$newdirectory/debian");
    $tar = Dpkg::Source::Archive->new(filename => "$dscdir$debianfile");
    $tar->extract($newdirectory, in_place => 1);

    # Apply patches (in a separate method as it might be overridden)
    $self->apply_patches($newdirectory, usage => 'unpack')
        unless $self->{options}{skip_patches};
}

sub get_autopatch_name {
    return 'zz_debian-diff-auto';
}

sub get_patches {
    my ($self, $dir, %opts) = @_;
    $opts{skip_auto} //= 0;
    my @patches;
    my $pd = "$dir/debian/patches";
    my $auto_patch = $self->get_autopatch_name();
    if (-d $pd) {
        opendir(my $dir_dh, $pd) or syserr(g_('cannot opendir %s'), $pd);
        foreach my $patch (sort readdir($dir_dh)) {
            # patches match same rules as run-parts
            next unless $patch =~ /^[\w-]+$/ and -f "$pd/$patch";
            next if $opts{skip_auto} and $patch eq $auto_patch;
            push @patches, $patch;
        }
        closedir($dir_dh);
    }
    return @patches;
}

sub apply_patches {
    my ($self, $dir, %opts) = @_;
    $opts{skip_auto} //= 0;
    my @patches = $self->get_patches($dir, %opts);
    return unless scalar(@patches);
    my $applied = File::Spec->catfile($dir, 'debian', 'patches', '.dpkg-source-applied');
    open(my $applied_fh, '>', $applied)
        or syserr(g_('cannot write %s'), $applied);
    print { $applied_fh } "# During $opts{usage}\n";
    my $timestamp = fs_time($applied);
    foreach my $patch ($self->get_patches($dir, %opts)) {
        my $path = File::Spec->catfile($dir, 'debian', 'patches', $patch);
        info(g_('applying %s'), $patch) unless $opts{skip_auto};
        my $patch_obj = Dpkg::Source::Patch->new(filename => $path);
        $patch_obj->apply($dir, force_timestamp => 1,
                          timestamp => $timestamp,
                          add_options => [ '-E' ]);
        print { $applied_fh } "$patch\n";
    }
    close($applied_fh);
}

sub unapply_patches {
    my ($self, $dir, %opts) = @_;
    my @patches = reverse($self->get_patches($dir, %opts));
    return unless scalar(@patches);
    my $applied = File::Spec->catfile($dir, 'debian', 'patches', '.dpkg-source-applied');
    my $timestamp = fs_time($applied);
    foreach my $patch (@patches) {
        my $path = File::Spec->catfile($dir, 'debian', 'patches', $patch);
        info(g_('unapplying %s'), $patch) unless $opts{quiet};
        my $patch_obj = Dpkg::Source::Patch->new(filename => $path);
        $patch_obj->apply($dir, force_timestamp => 1, verbose => 0,
                          timestamp => $timestamp,
                          add_options => [ '-E', '-R' ]);
    }
    unlink($applied);
}

sub upstream_tarball_template {
    my $self = shift;
    my $ext = '{' . join(',',
        sort map {
            compression_get_property($_, 'file_ext')
        } compression_get_list()) . '}';
    return '../' . $self->get_basename() . ".orig.tar.$ext";
}

sub can_build {
    my ($self, $dir) = @_;
    return 1 if $self->find_original_tarballs(include_supplementary => 0);
    return 1 if $self->{options}{create_empty_orig} and
                $self->find_original_tarballs(include_main => 0);
    return (0, sprintf(g_('no upstream tarball found at %s'),
                       $self->upstream_tarball_template()));
}

sub before_build {
    my ($self, $dir) = @_;
    $self->check_patches_applied($dir) if $self->{options}{preparation};
}

sub after_build {
    my ($self, $dir) = @_;
    my $applied = File::Spec->catfile($dir, 'debian', 'patches', '.dpkg-source-applied');
    my $reason = '';
    if (-e $applied) {
        open(my $applied_fh, '<', $applied)
            or syserr(g_('cannot read %s'), $applied);
        $reason = <$applied_fh>;
        close($applied_fh);
    }
    my $opt_unapply = $self->{options}{unapply_patches};
    if (($opt_unapply eq 'auto' and $reason =~ /^# During preparation/) or
        $opt_unapply eq 'yes') {
        $self->unapply_patches($dir);
    }
}

sub prepare_build {
    my ($self, $dir) = @_;
    $self->{diff_options} = {
        diff_ignore_regex => $self->{options}{diff_ignore_regex} .
                             '|(^|/)debian/patches/.dpkg-source-applied$',
        include_removal => $self->{options}{include_removal},
        include_timestamp => $self->{options}{include_timestamp},
        use_dev_null => 1,
    };
    push @{$self->{options}{tar_ignore}}, 'debian/patches/.dpkg-source-applied';
    $self->check_patches_applied($dir) if $self->{options}{preparation};
    if ($self->{options}{create_empty_orig} and
        not $self->find_original_tarballs(include_supplementary => 0))
    {
        # No main orig.tar, create a dummy one
        my $filename = $self->get_basename() . '.orig.tar.' .
                       $self->{options}{comp_ext};
        my $tar = Dpkg::Source::Archive->new(filename => $filename,
                                             compression_level => $self->{options}{comp_level});
        $tar->create();
        $tar->finish();
    }
}

sub check_patches_applied {
    my ($self, $dir) = @_;
    my $applied = File::Spec->catfile($dir, 'debian', 'patches', '.dpkg-source-applied');
    unless (-e $applied) {
        info(g_('patches are not applied, applying them now'));
        $self->apply_patches($dir, usage => 'preparation');
    }
}

sub generate_patch {
    my ($self, $dir, %opts) = @_;
    my ($dirname, $updir) = fileparse($dir);
    my $basedirname = $self->get_basename();
    $basedirname =~ s/_/-/;

    # Identify original tarballs
    my ($tarfile, %addonfile);
    my $comp_ext_regex = compression_get_file_extension_regex();
    my @origtarballs;
    foreach my $file (sort $self->find_original_tarballs()) {
        if ($file =~ /\.orig\.tar\.$comp_ext_regex$/) {
            if (defined($tarfile)) {
                error(g_('several orig.tar files found (%s and %s) but only ' .
                         'one is allowed'), $tarfile, $file);
            }
            $tarfile = $file;
            push @origtarballs, $file;
            $self->add_file($file);
            $self->add_file("$file.asc") if -e "$file.asc";
        } elsif ($file =~ /\.orig-([[:alnum:]-]+)\.tar\.$comp_ext_regex$/) {
            $addonfile{$1} = $file;
            push @origtarballs, $file;
            $self->add_file($file);
            $self->add_file("$file.asc") if -e "$file.asc";
        }
    }

    error(g_('no upstream tarball found at %s'),
          $self->upstream_tarball_template()) unless $tarfile;

    if ($opts{usage} eq 'build') {
        info(g_('building %s using existing %s'),
             $self->{fields}{'Source'}, "@origtarballs");
    }

    # Unpack a second copy for comparison
    my $tmp = tempdir("$dirname.orig.XXXXXX", DIR => $updir);
    push_exit_handler(sub { erasedir($tmp) });

    # Extract main tarball
    my $tar = Dpkg::Source::Archive->new(filename => $tarfile);
    $tar->extract($tmp);

    # Extract additional orig tarballs
    foreach my $subdir (keys %addonfile) {
        my $file = $addonfile{$subdir};
        $tar = Dpkg::Source::Archive->new(filename => $file);
        $tar->extract("$tmp/$subdir");
    }

    # Copy over the debian directory
    erasedir("$tmp/debian");
    system('cp', '-a', '--', "$dir/debian", "$tmp/");
    subprocerr(g_('copy of the debian directory')) if $?;

    # Apply all patches except the last automatic one
    $opts{skip_auto} //= 0;
    $self->apply_patches($tmp, skip_auto => $opts{skip_auto}, usage => 'build');

    # Create a patch
    my ($difffh, $tmpdiff) = tempfile($self->get_basename(1) . '.diff.XXXXXX',
                                      TMPDIR => 1, UNLINK => 0);
    push_exit_handler(sub { unlink($tmpdiff) });
    my $diff = Dpkg::Source::Patch->new(filename => $tmpdiff,
                                        compression => 'none');
    $diff->create();
    if ($opts{header_from} and -e $opts{header_from}) {
        my $header_from = Dpkg::Source::Patch->new(
            filename => $opts{header_from});
        my $analysis = $header_from->analyze($dir, verbose => 0);
        $diff->set_header($analysis->{patchheader});
    } else {
        $diff->set_header($self->get_patch_header($dir));
    }
    $diff->add_diff_directory($tmp, $dir, basedirname => $basedirname,
            %{$self->{diff_options}},
            handle_binary_func => $opts{handle_binary},
            order_from => $opts{order_from});
    error(g_('unrepresentable changes to source')) if not $diff->finish();

    if (-s $tmpdiff) {
        info(g_('local changes detected, the modified files are:'));
        my $analysis = $diff->analyze($dir, verbose => 0);
        foreach my $fn (sort keys %{$analysis->{filepatched}}) {
            print " $fn\n";
        }
    }

    # Remove the temporary directory
    erasedir($tmp);
    pop_exit_handler();
    pop_exit_handler();

    return $tmpdiff;
}

sub do_build {
    my ($self, $dir) = @_;
    my @argv = @{$self->{options}{ARGV}};
    if (scalar(@argv)) {
        usageerr(g_("-b takes only one parameter with format '%s'"),
                 $self->{fields}{'Format'});
    }
    $self->prepare_build($dir);

    my $include_binaries = $self->{options}{include_binaries};
    my @tar_ignore = map { "--exclude=$_" } @{$self->{options}{tar_ignore}};

    my $sourcepackage = $self->{fields}{'Source'};
    my $basenamerev = $self->get_basename(1);

    # Check if the debian directory contains unwanted binary files
    my $binaryfiles = Dpkg::Source::Package::V2::BinaryFiles->new($dir);
    my $unwanted_binaries = 0;
    my $check_binary = sub {
        if (-f and is_binary($_)) {
            my $fn = File::Spec->abs2rel($_, $dir);
            $binaryfiles->new_binary_found($fn);
            unless ($include_binaries or $binaryfiles->binary_is_allowed($fn)) {
                errormsg(g_('unwanted binary file: %s'), $fn);
                $unwanted_binaries++;
            }
        }
    };
    my $tar_ignore_glob = '{' . join(',',
        map { s/,/\\,/rg } @{$self->{options}{tar_ignore}}) . '}';
    my $filter_ignore = sub {
        # Filter out files that are not going to be included in the debian
        # tarball due to ignores.
        my %exclude;
        my $reldir = File::Spec->abs2rel($File::Find::dir, $dir);
        my $cwd = getcwd();
        # Apply the pattern both from the top dir and from the inspected dir
        chdir $dir or syserr(g_("unable to chdir to '%s'"), $dir);
        $exclude{$_} = 1 foreach glob($tar_ignore_glob);
        chdir $cwd or syserr(g_("unable to chdir to '%s'"), $cwd);
        chdir($File::Find::dir)
            or syserr(g_("unable to chdir to '%s'"), $File::Find::dir);
        $exclude{$_} = 1 foreach glob($tar_ignore_glob);
        chdir $cwd or syserr(g_("unable to chdir to '%s'"), $cwd);
        my @result;
        foreach my $fn (@_) {
            unless (exists $exclude{$fn} or exists $exclude{"$reldir/$fn"}) {
                push @result, $fn;
            }
        }
        return @result;
    };
    find({ wanted => $check_binary, preprocess => $filter_ignore,
           no_chdir => 1 }, File::Spec->catdir($dir, 'debian'));
    error(P_('detected %d unwanted binary file (add it in ' .
             'debian/source/include-binaries to allow its inclusion).',
             'detected %d unwanted binary files (add them in ' .
             'debian/source/include-binaries to allow their inclusion).',
             $unwanted_binaries), $unwanted_binaries)
         if $unwanted_binaries;

    # Handle modified binary files detected by the auto-patch generation
    my $handle_binary = sub {
        my ($self, $old, $new, %opts) = @_;

        my $file = $opts{filename};
        $binaryfiles->new_binary_found($file);
        unless ($include_binaries or $binaryfiles->binary_is_allowed($file)) {
            errormsg(g_('cannot represent change to %s: %s'), $file,
                     g_('binary file contents changed'));
            errormsg(g_('add %s in debian/source/include-binaries if you want ' .
                        'to store the modified binary in the debian tarball'),
                     $file);
            $self->register_error();
        }
    };

    # Create a patch
    my $autopatch = File::Spec->catfile($dir, 'debian', 'patches',
                                        $self->get_autopatch_name());
    my $tmpdiff = $self->generate_patch($dir, order_from => $autopatch,
                                        header_from => $autopatch,
                                        handle_binary => $handle_binary,
                                        skip_auto => $self->{options}{auto_commit},
                                        usage => 'build');
    unless (-z $tmpdiff or $self->{options}{auto_commit}) {
        info(g_('you can integrate the local changes with %s'),
             'dpkg-source --commit');
        error(g_('aborting due to unexpected upstream changes, see %s'),
              $tmpdiff);
    }
    push_exit_handler(sub { unlink($tmpdiff) });
    $binaryfiles->update_debian_source_include_binaries() if $include_binaries;

    # Install the diff as the new autopatch
    if ($self->{options}{auto_commit}) {
        make_path(File::Spec->catdir($dir, 'debian', 'patches'));
        $autopatch = $self->register_patch($dir, $tmpdiff,
                                           $self->get_autopatch_name());
        info(g_('local changes have been recorded in a new patch: %s'),
             $autopatch) if -e $autopatch;
        rmdir(File::Spec->catdir($dir, 'debian', 'patches')); # No check on purpose
    }
    unlink($tmpdiff) or syserr(g_('cannot remove %s'), $tmpdiff);
    pop_exit_handler();

    # Create the debian.tar
    my $debianfile = "$basenamerev.debian.tar." . $self->{options}{comp_ext};
    info(g_('building %s in %s'), $sourcepackage, $debianfile);
    my $tar = Dpkg::Source::Archive->new(filename => $debianfile,
                                         compression_level => $self->{options}{comp_level});
    $tar->create(options => \@tar_ignore, chdir => $dir);
    $tar->add_directory('debian');
    foreach my $binary ($binaryfiles->get_seen_binaries()) {
        $tar->add_file($binary) unless $binary =~ m{^debian/};
    }
    $tar->finish();

    $self->add_file($debianfile);
}

sub get_patch_header {
    my ($self, $dir) = @_;
    my $ph = File::Spec->catfile($dir, 'debian', 'source', 'local-patch-header');
    unless (-f $ph) {
        $ph = File::Spec->catfile($dir, 'debian', 'source', 'patch-header');
    }
    my $text;
    if (-f $ph) {
        open(my $ph_fh, '<', $ph) or syserr(g_('cannot read %s'), $ph);
        $text = file_slurp($ph_fh);
        close($ph_fh);
        return $text;
    }
    my $ch_info = changelog_parse(offset => 0, count => 1,
        file => File::Spec->catfile($dir, 'debian', 'changelog'));
    return '' if not defined $ch_info;
    my $header = Dpkg::Control->new(type => CTRL_UNKNOWN);
    $header->{'Description'} = "<short summary of the patch>\n";
    $header->{'Description'} .=
"TODO: Put a short summary on the line above and replace this paragraph
with a longer explanation of this change. Complete the meta-information
with other relevant fields (see below for details). To make it easier, the
information below has been extracted from the changelog. Adjust it or drop
it.\n";
    $header->{'Description'} .= $ch_info->{'Changes'} . "\n";
    $header->{'Author'} = $ch_info->{'Maintainer'};
    $text = "$header";
    run_vendor_hook('extend-patch-header', \$text, $ch_info);
    $text .= "\n---
The information above should follow the Patch Tagging Guidelines, please
checkout http://dep.debian.net/deps/dep3/ to learn about the format. Here
are templates for supplementary fields that you might want to add:

Origin: <vendor|upstream|other>, <url of original patch>
Bug: <url in upstream bugtracker>
Bug-Debian: https://bugs.debian.org/<bugnumber>
Bug-Ubuntu: https://launchpad.net/bugs/<bugnumber>
Forwarded: <no|not-needed|url proving that it has been forwarded>
Reviewed-By: <name and email of someone who approved the patch>
Last-Update: <YYYY-MM-DD>\n\n";
    return $text;
}

sub register_patch {
    my ($self, $dir, $patch_file, $patch_name) = @_;
    my $patch = File::Spec->catfile($dir, 'debian', 'patches', $patch_name);
    if (-s $patch_file) {
        copy($patch_file, $patch)
            or syserr(g_('failed to copy %s to %s'), $patch_file, $patch);
        chmod(0666 & ~ umask(), $patch)
            or syserr(g_("unable to change permission of '%s'"), $patch);
        my $applied = File::Spec->catfile($dir, 'debian', 'patches', '.dpkg-source-applied');
        open(my $applied_fh, '>>', $applied)
            or syserr(g_('cannot write %s'), $applied);
        print { $applied_fh } "$patch\n";
        close($applied_fh) or syserr(g_('cannot close %s'), $applied);
    } elsif (-e $patch) {
        unlink($patch) or syserr(g_('cannot remove %s'), $patch);
    }
    return $patch;
}

sub _is_bad_patch_name {
    my ($dir, $patch_name) = @_;

    return 1 if not defined($patch_name);
    return 1 if not length($patch_name);

    my $patch = File::Spec->catfile($dir, 'debian', 'patches', $patch_name);
    if (-e $patch) {
        warning(g_('cannot register changes in %s, this patch already exists'),
                $patch);
        return 1;
    }
    return 0;
}

sub do_commit {
    my ($self, $dir) = @_;
    my ($patch_name, $tmpdiff) = @{$self->{options}{ARGV}};

    $self->prepare_build($dir);

    # Try to fix up a broken relative filename for the patch
    if ($tmpdiff and not -e $tmpdiff) {
        $tmpdiff = File::Spec->catfile($dir, $tmpdiff)
            unless File::Spec->file_name_is_absolute($tmpdiff);
        error(g_("patch file '%s' doesn't exist"), $tmpdiff) if not -e $tmpdiff;
    }

    my $binaryfiles = Dpkg::Source::Package::V2::BinaryFiles->new($dir);
    my $handle_binary = sub {
        my ($self, $old, $new, %opts) = @_;
        my $fn = File::Spec->abs2rel($new, $dir);
        $binaryfiles->new_binary_found($fn);
    };

    unless ($tmpdiff) {
        $tmpdiff = $self->generate_patch($dir, handle_binary => $handle_binary,
                                         usage => 'commit');
        $binaryfiles->update_debian_source_include_binaries();
    }
    push_exit_handler(sub { unlink($tmpdiff) });
    unless (-s $tmpdiff) {
        unlink($tmpdiff) or syserr(g_('cannot remove %s'), $tmpdiff);
        info(g_('there are no local changes to record'));
        return;
    }
    while (_is_bad_patch_name($dir, $patch_name)) {
        # Ask the patch name interactively
        print g_('Enter the desired patch name: ');
        $patch_name = <STDIN>;
        next unless defined $patch_name;
        chomp $patch_name;
        $patch_name =~ s/\s+/-/g;
        $patch_name =~ s/\///g;
    }
    make_path(File::Spec->catdir($dir, 'debian', 'patches'));
    my $patch = $self->register_patch($dir, $tmpdiff, $patch_name);
    my @editors = ('sensible-editor', $ENV{VISUAL}, $ENV{EDITOR}, 'vi');
    my $editor = first { find_command($_) } @editors;
    if (not $editor) {
        error(g_('cannot find an editor'));
    }
    system($editor, $patch);
    subprocerr($editor) if $?;
    unlink($tmpdiff) or syserr(g_('cannot remove %s'), $tmpdiff);
    pop_exit_handler();
    info(g_('local changes have been recorded in a new patch: %s'), $patch);
}

package Dpkg::Source::Package::V2::BinaryFiles;

use Dpkg::ErrorHandling;
use Dpkg::Gettext;

use File::Path qw(make_path);
use File::Spec;

sub new {
    my ($this, $dir) = @_;
    my $class = ref($this) || $this;

    my $self = {
        dir => $dir,
        allowed_binaries => {},
        seen_binaries => {},
        include_binaries_path =>
            File::Spec->catfile($dir, 'debian', 'source', 'include-binaries'),
    };
    bless $self, $class;
    $self->load_allowed_binaries();
    return $self;
}

sub new_binary_found {
    my ($self, $path) = @_;

    $self->{seen_binaries}{$path} = 1;
}

sub load_allowed_binaries {
    my $self = shift;
    my $incbin_file = $self->{include_binaries_path};
    if (-f $incbin_file) {
        open(my $incbin_fh, '<', $incbin_file)
            or syserr(g_('cannot read %s'), $incbin_file);
        while (<$incbin_fh>) {
            chomp;
            s/^\s*//;
            s/\s*$//;
            next if /^#/ or length == 0;
            $self->{allowed_binaries}{$_} = 1;
        }
        close($incbin_fh);
    }
}

sub binary_is_allowed {
    my ($self, $path) = @_;
    return 1 if exists $self->{allowed_binaries}{$path};
    return 0;
}

sub update_debian_source_include_binaries {
    my $self = shift;

    my @unknown_binaries = $self->get_unknown_binaries();
    return unless scalar(@unknown_binaries);

    my $incbin_file = $self->{include_binaries_path};
    make_path(File::Spec->catdir($self->{dir}, 'debian', 'source'));
    open(my $incbin_fh, '>>', $incbin_file)
        or syserr(g_('cannot write %s'), $incbin_file);
    foreach my $binary (@unknown_binaries) {
        print { $incbin_fh } "$binary\n";
        info(g_('adding %s to %s'), $binary, 'debian/source/include-binaries');
        $self->{allowed_binaries}{$binary} = 1;
    }
    close($incbin_fh);
}

sub get_unknown_binaries {
    my $self = shift;
    return grep { not $self->binary_is_allowed($_) } $self->get_seen_binaries();
}

sub get_seen_binaries {
    my $self = shift;
    my @seen = sort keys %{$self->{seen_binaries}};
    return @seen;
}

1;

#
# Fink::SelfUpdate class
#
# Fink - a package manager that downloads source and installs it
# Copyright (c) 2001 Christoph Pfisterer
# Copyright (c) 2001-2003 The Fink Package Manager Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA	 02111-1307, USA.
#

package Fink::SelfUpdate;

use Fink::Services qw(&execute &version_cmp &print_breaking
					  &prompt &prompt_boolean &prompt_selection);
use Fink::Config qw($config $basepath $distribution);
use Fink::NetAccess qw(&fetch_url);
use Fink::Engine;
use Fink::Package;
use Fink::FinkVersion qw(&pkginfo_version);

use File::Find;

use strict;
use warnings;

BEGIN {
	use Exporter ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
	$VERSION	 = 1.00;
	@ISA		 = qw(Exporter);
	@EXPORT		 = qw();
	@EXPORT_OK	 = qw();	# eg: qw($Var1 %Hashit &func3);
	%EXPORT_TAGS = ( );		# eg: TAG => [ qw!name1 name2! ],
}
our @EXPORT_OK;

END { }				# module clean-up code here (global destructor)


### check for new Fink release

sub check {
	my $useopt = shift || 0;
	my ($srcdir, $finkdir, $latest_fink, $installed_version, $answer);

	$srcdir = "$basepath/src";
	$finkdir = "$basepath/fink";
	if ($useopt != 0) {
		&print_breaking("\n Please note: the command 'fink selfupdate' "
				. "should be used for routine updating; you only need to use " 
				. "'fink selfupdate-cvs' or 'fink selfupdate-rsync' if you are "
				. "changing your update method. \n\n");
	}
	if ((! defined($config->param("SelfUpdateMethod") )) and ! $useopt == 0){
		if ($useopt == 1) {
			$answer = "cvs";	
		}
		elsif ($useopt == 2) {
			$answer = "rsync";
		}
		else {
		    $answer = "point";
		}
		&print_breaking("fink is setting your default update method to $answer \n");
		$config->set_param("SelfUpdateMethod", $answer);
		$config->save();
	}

	# The user has not chosen a selfupdatemethod yet, always ask
	# if the fink.conf setting is not there.
	if ((! defined($config->param("SelfUpdateMethod") )) and $useopt == 0){
		&print_breaking("fink needs you to choose a SelfUpdateMethod. \n");
		$answer = &prompt_selection("Choose an update method", 1, {"rsync" => "rsync",
			"cvs" => "cvs", "point" => "Stick to point releases"}, "rsync","cvs","point");
		$config->set_param("SelfUpdateMethod", $answer);
		$config->save();	
	    }

	# By now the config param SelfUpdateMethod should be set.
	if (($config->param("SelfUpdateMethod") eq "cvs") and $useopt != 2){
		if (-f "$finkdir/stamp-rsync-live") {
			unlink "$finkdir/stamp-rsync-live";
		}
		if (-d "$finkdir/dists/CVS") {
			&do_direct_cvs();
			&do_finish();
			return;
		} else {
			&setup_direct_cvs();
			&do_finish();
			return;
		}
	}
	elsif (($config->param("SelfUpdateMethod") eq "rsync") and $useopt != 1){
		&do_direct_rsync();
		&do_finish();
		return;
	}
	# Hm, we were called with a different option than the default :(
	$installed_version = &pkginfo_version();
	my $selfupdatemethod = $config->param("SelfUpdateMethod");
	if (($selfupdatemethod ne "rsync") and $useopt == 2) {
		$answer =
			&prompt_boolean("The current selfupdate method is $selfupdatemethod. " 
					. "Do you wish to change the default selfupdate method ".
				"to rsync?",1);
		if (! $answer) {
			return;
		    }
		$config->set_param("SelfUpdateMethod", "rsync");
		$config->save();	
		&do_direct_rsync();
		&do_finish();
		return;		
	    }
	if (($selfupdatemethod ne "cvs") and $useopt == 1) {
		$answer =
			&prompt_boolean("The current selfupdate method is $selfupdatemethod. " 
					. "Do you wish to change the default selfupdate method ".
				"to cvs?",1);
		if (! $answer) {
			return;
		}
		$config->set_param("SelfUpdateMethod", "cvs");
		$config->save();	
		&setup_direct_cvs();
		&do_finish();
		return;
	}
	if (($config->param("SelfUpdateMethod") eq "point")) {
		# get the file with the current release number
	        my $distro = $Fink::Config::distribution;
		my $currentfink;
		$currentfink = "CURRENT-FINK-$distro";
		### if we are in 10.1, need to use "LATEST-FINK" not "CURRENT-FINK"
		if ($distro =~ /10.1/) {
				$currentfink = "LATEST-FINK";
		}
	
		if (&fetch_url("http://fink.sourceforge.net/$currentfink", $srcdir)) {
			die "Can't get latest version info\n";
		}
		$latest_fink = `cat $srcdir/$currentfink`;
		chomp($latest_fink);
		if ( ! -f "$finkdir/stamp-cvs-live" and ! -f "$finkdir/stamp-rsync-live" )
		{
			# check if we need to upgrade
			if (&version_cmp($latest_fink . '-1', '<=', $installed_version . '-1')) {
				print "\n";
				&print_breaking("You already have the package descriptions from ".
								"the latest Fink point release. ".
								"(installed:$installed_version available:$latest_fink)");
				return;
			}
		} else {
			&execute("rm -f $finkdir/stamp-rsync-live $finkdir/stamp-cvs-live");
			&execute("find $finkdir -name \"CVS\" -type d | xargs rm -rf");
		}
		&do_tarball($latest_fink);
		&do_finish();
	}
}

### set up direct cvs

sub setup_direct_cvs {
	my ($finkdir, $tempdir, $tempfinkdir);
	my ($username, $cvsuser, @testlist);
	my ($use_hardlinks, $cutoff, $cmd);
	my ($cmdd);


	$username = "root";
	if (exists $ENV{SUDO_USER}) {
		$username = $ENV{SUDO_USER};
	}

	print "\n";
	$username =
		&prompt("Fink has the capability to run the CVS commands as a ".
				"normal user. That has some advantages - it uses that ".
				"user's CVS settings files and allows the package ".
				"descriptions to be edited and updated without becoming ".
				"root. Please specify the user login name that should be ".
				"used:",
				$username);

	# sanity check
	@testlist = getpwnam($username);
	if (scalar(@testlist) <= 0) {
		die "The user \"$username\" does not exist on the system.\n";
	}

	print "\n";
	$cvsuser =
		&prompt("For Fink developers only: ".
				"Enter your SourceForge login name to set up full CVS access. ".
				"Other users, just press return to set up anonymous ".
				"read-only access.",
				"anonymous");
	print "\n";

	# start by creating a temporary directory with the right permissions
	$finkdir = "$basepath/fink";
	$tempdir = "$finkdir.tmp";
	$tempfinkdir = "$tempdir/fink";

	if (-d $tempdir) {
		if (&execute("rm -rf $tempdir")) {
			die "Can't remove left-over temporary directory '$tempdir'\n";
		}
	}
	if (&execute("mkdir -p $tempdir")) {
		die "Can't create temporary directory '$tempdir'\n";
	}
	if ($username ne "root") {
		if (&execute("chown $username $tempdir")) {
			die "Can't set ownership of temporary directory '$tempdir'\n";
		}
	}

	# check if hardlinks from the old directory work
	&print_breaking("Checking to see if we can use hard links to merge ".
					"the existing tree. Please ignore errors on the next ".
					"few lines.");
	if (&execute("touch $finkdir/README; ln $finkdir/README $tempdir/README")) {
		$use_hardlinks = 0;
	} else {
		$use_hardlinks = 1;
	}
	unlink "$tempdir/README";

	# start the CVS fun
	chdir $tempdir or die "Can't cd to $tempdir: $!\n";

	# add cvs quiet flag if verbosity level permits
	my $verbosity = "-q";
	if (Fink::Config::verbosity_level() > 1) {
		$verbosity = "";
	}
	if ($cvsuser eq "anonymous") {
		&print_breaking("Now logging into the CVS server. When CVS asks you ".
						"for a password, just press return (i.e. the password ".
						"is empty).");
		$cmd = "cvs -d:pserver:anonymous\@cvs.sourceforge.net:/cvsroot/fink login";
		if ($username ne "root") {
			$cmd = "su $username -c '$cmd'";
		}
		if (&execute($cmd)) {
			die "Logging into the CVS server for anonymous read-only access failed.\n";
		}

		$cmd = "cvs ${verbosity} -z3 -d:pserver:anonymous\@cvs.sourceforge.net:/cvsroot/fink";
	} else {
		$cmd = "cvs ${verbosity} -z3 -d:ext:$cvsuser\@cvs.sourceforge.net:/cvsroot/fink";
		$ENV{CVS_RSH} = "ssh";
	}
	$cmdd = "$cmd checkout -d fink dists";
	if ($username ne "root") {
		$cmdd = "su $username -c '$cmdd'";
	}
	&print_breaking("Now downloading package descriptions...");
	if (&execute($cmdd)) {
		die "Downloading package descriptions from CVS failed.\n";
	}
	if ($Fink::Config::distribution =~ /10.1/) { #must do a second checkout in this case
			chdir "fink" or die "Can't cd to fink\n";
			$cmdd = "$cmd checkout -d 10.1 packages/dists";
			if ($username ne "root") {
					$cmdd = "su $username -c '$cmdd'";
			}
			&print_breaking("Now downloading more package descriptions...");
			if (&execute($cmdd)) {
					die "Downloading package descriptions from CVS failed.\n";
			}
			chdir $tempdir or die "Can't cd to $tempdir: $!\n";
	}
	if (not -d $tempfinkdir) {
		die "The CVS didn't report an error, but the directory '$tempfinkdir' ".
			"doesn't exist as expected. Strange.\n";
	}

	# merge the old tree
	$cutoff = length($finkdir)+1;
	find(sub {
				 if ($_ eq "CVS") {
					 $File::Find::prune = 1;
					 return;
				 }
				 return if (length($File::Find::name) <= $cutoff);
				 my $rel = substr($File::Find::name, $cutoff);
				 if (-l and not -e "$tempfinkdir/$rel") {
					 my $linkto;
					 $linkto = readlink($_)
						 or die "Can't read target of symlink $File::Find::name: $!\n";
					 if (&execute("ln -s '$linkto' '$tempfinkdir/$rel'")) {
						 die "Can't create symlink \"$tempfinkdir/$rel\"\n";
					 }
				 } elsif (-d and not -d "$tempfinkdir/$rel") {
					 if (&execute("mkdir -p '$tempfinkdir/$rel'")) {
						 die "Can't create directory \"$tempfinkdir/$rel\"\n";
					 }
				 } elsif (-f and not -f "$tempfinkdir/$rel") {
					 my $cmd;
					 if ($use_hardlinks) {
						 $cmd = "ln";
					 } else {
						 $cmd = "cp -p"
					 }
					 $cmd .= " '$_' '$tempfinkdir/$rel'";
					 if (&execute($cmd)) {
						 die "Can't copy file \"$tempfinkdir/$rel\"\n";
					 }
				 }
			 }, $finkdir);

	# switch $tempfinkdir to $finkdir
	chdir $basepath or die "Can't cd to $basepath: $!\n";
	if (&execute("mv $finkdir $finkdir.old")) {
		die "Can't move \"$finkdir\" out of the way\n";
	}
	if (&execute("mv $tempfinkdir $finkdir")) {
		die "Can't move new tree \"$tempfinkdir\" into place at \"$finkdir\". ".
			"Warning: Your Fink installation is in an inconsistent state now.\n";
	}
	&execute("rm -rf $tempdir");

	print "\n";
	&print_breaking("Your Fink installation was successfully set up for ".
					"direct CVS updating. The directory \"$finkdir.old\" ".
					"contains your old package description tree. Its ".
					"contents were merged into the new one, but the old ".
					"tree was left intact for safety reasons. If you no ".
					"longer need it, remove it manually.");
	print "\n";
}

### call cvs update

sub do_direct_cvs {
	my ($descdir, @sb, $cmd, $username, $msg);

	# add cvs quiet flag if verbosity level permits
	my $verbosity = "-q";
	if (Fink::Config::verbosity_level() > 1) {
		$verbosity = "";
	}

	$descdir = "$basepath/fink";
	chdir $descdir or die "Can't cd to $descdir: $!\n";

	@sb = stat("$descdir/CVS");
	$cmd = "cvs ${verbosity} -z3 update -d -P";
	$msg = "I will now run the cvs command to retrieve the latest package ".
			"descriptions. ";

	if ($sb[4] != 0 and $> != $sb[4]) {
		($username) = getpwuid($sb[4]);
		$cmd = "su $username -c '$cmd'";
		$msg .= "The 'su' command will be used to run the cvs command as the ".
				"user '$username'. ";
	}

	$msg .= "After that, the core packages will be updated right away; ".
			"you should then update the other packages using commands like ".
			"'fink update-all'.";

	print "\n";
	&print_breaking($msg);
	print "\n";

	$ENV{CVS_RSH} = "ssh";
	if (&execute($cmd)) {
		die "Updating using CVS failed. Check the error messages above.\n";
	}
}

### update from packages tarball
# parameter: version number

sub do_tarball {
	my $newversion = shift;
	my ($downloaddir, $dir);
	my ($pkgtarball, $url, $verbosity, $unpack_cmd);

	print "\n";
	&print_breaking("I will now download the package descriptions for ".
					"Fink $newversion and update the core packages. ".
					"After that, you should update the other packages ".
					"using commands like 'fink update-all'.");
	print "\n";

	$downloaddir = "$basepath/src";
	chdir $downloaddir or die "Can't cd to $downloaddir: $!\n";

	# go ahead and upgrade
	# first, download the packages tarball
	$dir = "dists-$newversion";

	### if we are in 10.1, need to use "packages" not "dists"
	if ($Fink::Config::distribution =~ /10.1/) {
			$dir = "packages-$newversion";
	}
	
	$pkgtarball = "$dir.tar.gz";
	$url = "mirror:sourceforge:fink/$pkgtarball";

	if (not -f $pkgtarball) {
		if (&fetch_url($url, $downloaddir)) {
			die "Downloading the update tarball '$pkgtarball' from the URL '$url' failed.\n";
		}
	}

	# unpack it
	if (-e $dir) {
		if (&execute("rm -rf $dir")) {
			die "can't remove existing directory $dir\n";
		}
	}

	$verbosity = "";
	if (Fink::Config::verbosity_level() > 1) {
		$verbosity = "v";
	}
	$unpack_cmd = "tar -xz${verbosity}f $pkgtarball";
	if (&execute($unpack_cmd)) {
		die "unpacking $pkgtarball failed\n";
	}

	# inject it
	chdir $dir or die "Can't cd into $dir: $!\n";
	if (&execute("./inject.pl $basepath -quiet")) {
		die "injecting the new package definitions from $pkgtarball failed\n";
	}
	chdir $downloaddir or die "Can't cd to $downloaddir: $!\n";
	if (-e $dir) {
		&execute("rm -rf $dir");
	}
}

### last steps: reread descriptions, update fink, re-exec

sub do_finish {
	my $package;

	# re-read package info
	Fink::Package->forget_packages();
	Fink::Package->require_packages();


	# update the package manager itself first if necessary (that is, if a
	# newer version is available).
	$package = Fink::PkgVersion->match_package("fink");
	if (not $package->is_installed()) {
		Fink::Engine::cmd_install("fink");
	
		# delete the old package DB, so that the new package manager rebuilds it
		if (-e "$basepath/var/db/fink.db") {
			unlink "$basepath/var/db/fink.db";
		}
		
		# re-execute ourselves before we update the rest
		print "Re-executing fink to use the new version...\n";
		exec "$basepath/bin/fink selfupdate-finish";
	
		# the exec doesn't return, but just in case...
		die "re-executing fink failed, run 'fink selfupdate-finish' manually\n";
	} else {
		# package manager was not updated, just finish selfupdate directly
		&finish();
	}
}

### finish self-update (after upgrading fink itself and re-exec)

sub finish {
	my (@elist);

	# determine essential packages
	@elist = Fink::Package->list_essential_packages();

	# add some non-essential but important ones
	push @elist, qw(apt apt-shlibs storable-pm bzip2-dev gettext-dev gettext-bin libiconv-dev ncurses-dev);

	# update them
	Fink::Engine::cmd_install(@elist);	

	# tell the user what has happened
	print "\n";
	&print_breaking("The core packages have been updated. ".
					"You should now update the other packages ".
					"using commands like 'fink update-all'.");
	print "\n";
}

sub rsync_check {
	&do_direct_rsync();
	&do_finish();
}

sub do_direct_rsync {
	my ($descdir, @sb, $cmd, $tree, $rmcmd, $vercmd, $username, $msg);
	my $dist = $Fink::Config::distribution;
	my $rsynchost = $config->param_default("Mirror-rsync", "rsync://master.us.finkmirrors.net/finkinfo/");
	my $touchcmd = "touch stamp-rsync-live && rm -f stamp-cvs-live";
	# add rsync quiet flag if verbosity level permits
	my $verbosity = "-q";
	if (Fink::Config::verbosity_level() > 1) {
		$verbosity = "-v";
	}

	$descdir = "$basepath/fink";
	chdir $descdir or die "Can't cd to $descdir: $!\n";

	# If the Distributions line has been updated...
	if (! -d "$descdir/$dist") {
		&execute("mkdir -p '$descdir/$dist'")
	}
	@sb = stat("$descdir/$dist");

	# We need to remove the CVS directories, since what we're
	# going to put there isn't from cvs.  Leaving those directories
	# there will thoroughly confuse things if someone later does 
	# selfupdate-cvs.  However, don't actually do the removal until
	# we've tried to put something there.
	$vercmd = "rsync -az $verbosity $rsynchost/VERSION $basepath/fink/VERSION";
	$msg = "I will now run the rsync command to retrieve the latest package descriptions. \n";
	&print_breaking($msg);
	foreach $tree ($config->get_treelist()) {
		next unless ($tree =~ /stable/);

		$rsynchost =~ s/\/*$//;
		$dist      =~ s/\/*$//;
		$tree      =~ s/\/*$//;

		my $rsyncpath;

		if ($tree =~ m#/[^/]*/#) {
			# the user specificed a dist as well as a tree in their Trees: line
			$rsyncpath = "$rsynchost/$tree/finkinfo";
		} else {
			# a standard Trees: entry
			$rsyncpath = "$rsynchost/$dist/$tree/finkinfo";
		}

		$cmd = "rsync -az --delete-after $verbosity '$rsyncpath' '$basepath/fink/$dist/$tree/'";
		if (! -d "$basepath/fink/$dist/$tree" ) {
			&execute("mkdir -p '$basepath/fink/$dist/$tree'")
		}
		if (system("rsync '$rsyncpath' >/dev/null 2>&1") == 0) {
			$msg = "Updating $tree \n";
			if ($sb[4] != 0 and $> != $sb[4]) {
				($username) = getpwuid($sb[4]);
				$cmd = "su $username -c \"$cmd\"";
				system("chown -R $username '$basepath/fink/$dist'");
			}
			&print_breaking($msg);
			if (&execute($cmd)) {
				die "Updating $tree using rsync failed. Check the error messages above.\n";
			} else {
				&execute("find '$basepath/fink/$dist/$tree' -type d -name CVS | xargs rm -rf");
			}
		} else {
			print "Warning: $tree exists in fink.conf, but is not on rsync server.  Skipping.\n";
		}
		&execute("rm -rf '$basepath/fink/$dist/CVS'");
	}
	&execute("rm -rf '$basepath/fink/CVS'");
	&execute($vercmd);
	&execute($touchcmd);
}


### EOF
1;

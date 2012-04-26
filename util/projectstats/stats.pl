#!/usr/bin/perl
use strict;
use warnings;

# global variables
my @repos;
my %commits;
my $remote = "origin";
my $limit = 0;

sub mapAuthorToEmployer($) {
    return "(bot)" if $_ eq "qt_submodule_update_bot\@ovi.com";
    /(.*)@(.*)/;
    my $user = $1;
    my $domain = $2;
    return "nokia.com" if ($domain eq "ovi.com");
    return "$user\@$domain" if ($domain eq "gmail.com" || $domain eq "kde.org");
    return "QNX (by kdab.com)" if $_ =~ /\.qnx\@kdab.com/;
    return $domain;
}

sub mapToEmployers($) {
    my %commits = %{$_[0]};
    my %result;
    while (my ($key, $list) = each %commits) {
	$result{$key} = [ map { mapAuthorToEmployer($_) } @{$list} ];
    }
    return \%result;
}

sub recurseSubmodules()
{
    my @newrepos = @repos;
    @repos = ();

    while (scalar @newrepos) {
	# Get the submodules of this module, if any
	my $repo = shift @newrepos;
	push @repos, $repo;
	chdir($repo) or die "Failed to chdir to $repo: $!";
	open GIT_SUBMODULE, "-|",
	    "git", "submodule", "--quiet", "foreach", 'echo $PWD'
		or die("Cannot run git-submodule: $!");
	while (<GIT_SUBMODULE>) {
	    chomp;
	    push @newrepos, $_;
	}
	close GIT_SUBMODULE;
    }
}

sub getAllCommits() {
    use POSIX qw(strftime);
    my $end = time;
    $end = int(($end / 86400 + 4) / 7) * 7;
    $end -= 4;
    $end *= 86400;
    my $begin = $end - 16 * 7 * 86400 + 86400;

    $begin = strftime("%a %F", gmtime($begin));
    $end = strftime("%a %F", gmtime($end));

    print "\"Data from $begin to $end\"\n\n";

    foreach my $repo (@repos) {
	chdir($repo) or die;

	# Get a listing of branches in the remote
	open GIT, "-|",
  	    "git", "for-each-ref", "--format=%(objectname)", "refs/remotes/$remote"
		or die "Cannot run git-for-each-ref on $repo: $!";
	my @branches = map { chomp; $_ } <GIT>;
	close GIT;
	die "git-for-each-ref error" if $?;

	# Now get a listing of every committer in those branches
	open GIT, "-|",
	    "git", "log", "--since=$begin", "--until=$end",
	    "--pretty=format:%ae %ct", @branches
		or die("Cannot run git-log on $repo: $!");
	while (<GIT>) {
	    chomp;
	    my ($author, $date) = split / /;
	    my $week = strftime "%YW%V", gmtime($date);
	    push @{$commits{$week}}, $author;
	}
	close GIT;
	die "git-log error" if $?;
    }
}

sub printAuthorStats($) {
    my %commits = %{$_[0]};
    my %activity_per_week;
    my %activity_overall;
    my %total_per_week;
    while (my ($week, $commits) = each %commits) {
	foreach my $author (@{$commits}) {
	    # Author stats
	    $activity_per_week{$author}{$week}++;
	    $activity_overall{$author}++;

	    # overall stats
	    $total_per_week{$week}++;
	}
    }

    # sort by decreasing order of activity
    my @sorted_authors =
	sort { $activity_overall{$b} <=> $activity_overall{$a} }
        keys %activity_overall;
    @sorted_authors = @sorted_authors[0 .. $limit - 1]
	if $limit > 0;

    my @sorted_weeks = sort keys %total_per_week;

    # print week header
    map { print ',"' . $_ . '"' } @sorted_weeks;
    print "\n";

    # print data
    my %total_printed;
    foreach my $author (@sorted_authors) {
	my %this_author = %{$activity_per_week{$author}};
	print "\"$author\",";

	foreach my $week (@sorted_weeks) {
	    my $count = $this_author{$week};
	    $count = 0 unless defined($count);
	    $total_printed{$week} += $count;
	    print "$count,";
	}
	print "\n";
    }

    # print the "others" line
    if ($limit > 0) {
	print '"others",';
	foreach my $week (@sorted_weeks) {
	    print $total_per_week{$week} - $total_printed{$week};
	    print ',';
	}
	print "\n";
    }
    print "\n";
}

sub printSummary() {
    my %total_per_week;
    my $grand_total;
    while (my ($week, $commits) = each %commits) {
	foreach my $author (@{$commits}) {
	    # overall stats
	    $total_per_week{$week}++;
	    $grand_total++;
	}
    }

    my @sorted_weeks = sort keys %total_per_week;
    map { print ',"' . $_ . '"' } @sorted_weeks;
    print "\n";
    print '"Total",';
    map { printf "%d,", $total_per_week{$_} } @sorted_weeks;
    print "\n\n";

    print '"Grand Total",' . $grand_total . "\n"
}

my $recurse = 1;
while (scalar @ARGV) {
    $_ = shift @ARGV;
    s/^--/-/;
    my $argvalue = 1;
    s/^-no-// and $argvalue = 0;
    if (/^-recurse/) {
	$recurse = $argvalue;
    } elsif (/-^remote/) {
	$remote = shift @ARGV;
    } elsif (/^-limit/) {
	$limit = shift @ARGV;
    } elsif (!/^-/) {
	push @repos, $_;
    }
}

recurseSubmodules() if $recurse;
getAllCommits();
printAuthorStats(\%commits);
printAuthorStats(\%{mapToEmployers(\%commits)});
printSummary();

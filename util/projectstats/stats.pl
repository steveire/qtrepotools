#!/usr/bin/perl
use strict;
use warnings;

# global variables
my @repos;
my %commits;
my $remote = "origin";
my $limit = 0;
my $csvfh;
my $gnuplot;
my $gnuplotmaster;

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

    print STDERR "Data from $begin to $end\n";

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

sub printCsvStats($) {
    select $csvfh;
    my %commits = %{$_[0]};
    my %activity_per_week;
    my %activity_overall;
    my %total_per_week;
    while (my ($week, $commits) = each %commits) {
        foreach my $author (@{$commits}) {
            # Author stats
            $activity_per_week{$week}{$author}++;
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

    # print author header
    map { print ',"' . $_ . '"' } @sorted_authors;
    print ',"others"' if $limit > 0;
    print "\n";

    # print data
    foreach my $week (@sorted_weeks) {
        my %this_week = %{$activity_per_week{$week}};
        my $total_printed = 0;
        print "\"$week\",";

        foreach my $author (@sorted_authors) {
            my $count = $this_week{$author};
            $count = 0 unless defined($count);
            $total_printed += $count;
            print "$count,";
        }

        # print the "others" column
        print $total_per_week{$week} - $total_printed
            if $limit > 0;
        print "\n";
    }
    print "\n";
    select STDOUT;
}

sub printCsvSummary() {
    my %total_per_week;
    my $grand_total;
    while (my ($week, $commits) = each %commits) {
        foreach my $author (@{$commits}) {
            # overall stats
            $total_per_week{$week}++;
            $grand_total++;
        }
    }

    select $csvfh;
    my @sorted_weeks = sort keys %total_per_week;
    map { print ',"' . $_ . '"' } @sorted_weeks;
    print "\n";
    print '"Total",';
    map { printf "%d,", $total_per_week{$_} } @sorted_weeks;
    print "\n\n";

    print '"Grand Total",' . $grand_total . "\n";
    select STDOUT;
}

sub printGnuplotStats($%) {
    my $dataname = $_[0];
    my %commits = %{$_[1]};
    my $datafile = "$gnuplot.$dataname.dat";
    my %activity_per_week;
    my %activity_overall;
    my %total_per_week;
    while (my ($week, $commits) = each %commits) {
        foreach my $author (@{$commits}) {
            # Author stats
            $activity_per_week{$week}{$author}++;
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

    my $colcount = scalar @sorted_authors + 3;

    # write the plot
    select $gnuplotmaster;
    print <<END;
        reset
        set terminal png size 1400, 600
        set key center below
        set key autotitle columnhead
        set style fill solid
        set format x "%s"
        set xlabel "Weeks"
        set ylabel "Commits"

        accumulate(c) = column(c) + (c > 3 ? accumulate(c - 1) : 0)

        set output '$gnuplot.$dataname.total.png'
        plot '$datafile' using 1:(accumulate($colcount)):xticlabels(2) \\
            with filledcurves x1 linecolor 3

        set output '$gnuplot.$dataname.absolute.png'
        plot for [i = $colcount:3:-1] \\
            '$datafile' using 1:(accumulate(i)):xticlabels(2) \\
            title columnhead(i) with filledcurves x1 linecolor i-1

        set output '$gnuplot.$dataname.relative.png'
        set yrange [0:100]
        set format y '%.0f%%'
        plot for [i = $colcount:3:-1] \\
            '$datafile' using 1:(100*accumulate(i)/accumulate($colcount)):xticlabels(2) \\
            title columnhead(i) with filledcurves x1 linecolor i-1

END

    # write data
    open DATAFILE, ">", $datafile
        or die "Cannot open data file $datafile: $!";
    select DATAFILE;

    print 'idx Week ';
    map { print "\"$_\" "; } @sorted_authors;
    print 'others ' if $limit > 0;
    print "\n";
    my $i = 0;
    foreach my $week (@sorted_weeks) {
        my %this_week = %{$activity_per_week{$week}};
        my $total_printed = 0;
        print "$i \"$week\" ";

        foreach my $author (@sorted_authors) {
            my $count = $this_week{$author};
            $count = 0 unless defined($count);
            $total_printed += $count;
            print "$count ";
        }

        # print the "others" column
        print $total_per_week{$week} - $total_printed
            if $limit > 0;
        print "\n";
        $i++;
    }

    close DATAFILE;
    select STDOUT;
}

my $recurse = 1;
my $csv;
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
    } elsif (/^-csv/) {
        $csv = shift @ARGV;
    } elsif (/^-gnuplot/) {
        $gnuplot = shift @ARGV;
    } elsif (!/^-/) {
        push @repos, $_;
    }
}

die "No output defined, not doing anything\n" .
    "Please use --csv <outputfile> or --gnuplot <basename>"
    unless defined($csv) or defined($gnuplot);

if (!defined($csv)) {
} elsif ($csv eq "-") {
    open($csvfh, ">&STDOUT");
} else {
    open($csvfh, ">", $csv)
        or die "Cannot open output file $csv: $!";
}

if (!defined($gnuplot)) {
} elsif ($gnuplot eq "-") {
    open($gnuplotmaster, ">&STDOUT");
    # write the secondary data files to "gnuplot.NNN.dat"
    $gnuplot = "gnuplot";
} else {
    open($gnuplotmaster, ">", $gnuplot)
        or die "Cannot open output file $csv: $!";
}

my $pwd = `pwd`;
chomp $pwd;
recurseSubmodules() if $recurse;
getAllCommits();
chdir $pwd or die;
my %employerCommits = %{mapToEmployers(\%commits)};
if (defined($csv)) {
    printCsvStats(\%commits);
    printCsvStats(\%employerCommits);
    printCsvSummary();
}
if (defined($gnuplot)) {
    printGnuplotStats("author", \%commits);
    printGnuplotStats("employer", \%employerCommits);
}

# -*- mode: perl; encoding: utf-8; indent-tabs-mode: nil -*-

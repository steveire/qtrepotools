#!/usr/bin/perl
use strict;
use warnings;

# perl stats.pl ~/dev/src/cmake --gnuplot cmake --since "4 years ago" --exclude "kwrobot@kitware.com" --exclude "libarchive-discuss@googlegroups.com" --exclude "curl-library@cool.haxx.se" --limit 10 --mode monthly --refs refs/heads/master --diffstat && gnuplot cmake.gnuplot

# global variables
my @repos;
my %branchstats;
my @sorted_branches;
my %commits;
my %commitdiffstats;
my $refs = "refs/remotes/origin";
my $limit = 0;
my $csvfh;
my $gnuplot;
my $gnuplotmaster;
my @exclude;
my $mode = "weekly";
my $since;
my $diffstat = 0;

my @genericDomains = qw(gmail.com googlemail.com hotmail.com
kde.org kdemail.net kate-editor.org oxygen-icons.org mail.com
freedesktop.org gnome.org sourceforge.net
gentoo.org fedoraproject.org freebsd.org free.fr freenet.de
gmx.at gmx.com gmx.de gmx.net terra.es web.de webspeed.dk yahoo.com yahoo.fr
tiscali.it yandex.ru me.com email.cz iki.fi
);

sub mapAuthorToAuthor($) {
    $_ = $_[0];
    return "hjk121\@nokiamail.com" if $_ eq "qtc-committer\@nokia.com";
    return "hjk121\@nokiamail.com" if $_ eq "qthjk\@ovi.com";
    return "erich.keane\@intel.com" if $_ eq "erich.keane\@verizon.net";
    return $_;
}

sub mapAuthorToEmployer($) {
    $_ = $_[0];
    return "(bot)" if $_ eq "qt_submodule_update_bot\@ovi.com";
    return "(bot)" if $_ eq "scripty\@kde.org";
    /(.*)@(.*)/ or return $_;
    my $user = $1;
    my $domain = lc $2;
    return "digia.com" if ($_ eq "qt_aavit\@ovi.com");
    return "digia.com" if ($_ eq "hjk121\@nokiamail.com");
    return "(individuals)" if grep { $_ eq $domain } @genericDomains;
    return "QNX (by kdab.com)" if $_ =~ /\.qnx\@kdab.com/;
    return "blackberry.com" if $domain eq "rim.com";
    return "intel.com" if $_ =~ /.intel.com$/;
    return $domain;
}

sub mapToEmployers($) {
    my %commits = %{$_[0]};
    my %result;
    while (my ($key, $list) = each %commits) {
        while (my ($author, $count) = each %{$list}) {
            my $employer = mapAuthorToEmployer $author;
            $result{$key}{$employer} = 0
                unless defined($result{$key}{$employer});
            $result{$key}{$employer} += $count;
        }
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
    my $begin;
    my $end = time;
    my $timeformat;

    if ($mode eq "weekly") {
        # Get the last 16 weeks
        $timeformat = "%GW%V";
        $end = int(($end / 86400 + 4) / 7) * 7;
        $end -= 4;
        $end *= 86400;
        $begin = $end - 16 * 7 * 86400 + 86400;
        $begin = strftime("%a %F", gmtime($begin));
        $end = strftime("%a %F", gmtime($end));
    } else { #monthly
        # Get the last 6 months
        $timeformat = "%Y-%m";

        my @breakdown = gmtime $end;
        # Day 0 is the last day of the previous month
        $end = [ (0, 0, 0, 0, $breakdown[4], $breakdown[5]) ];
        $breakdown[4] -= 6;
        if ($breakdown[4] < 0) {
            $breakdown[4] += 12;
            $breakdown[5]--;
        }
        $begin = [ (0, 0, 0, 1, $breakdown[4], $breakdown[5]) ];

        $begin = strftime("%a %F", @{$begin});
        $end = strftime("%a %F", @{$end});
    }


    $begin = $since if defined($since);
    print STDERR "Data from $begin to $end\n";

    foreach my $repo (@repos) {
        chdir($repo) or die("chdir: $repo: $!");

        # Get a listing of tags in the repo, in creation order
        open GIT, "-|",
            "git", "for-each-ref", "--sort=taggerdate",
            "--format=%(refname:short)", "refs/tags"
                or die "Cannot run git-for-each-ref on $repo: $!";
        @sorted_branches = map { chomp; $_ } <GIT>;
        close GIT;
        die "git-for-each-ref error" if $?;

        if ($refs =~ /\*$/) {
            # Get a listing of branches in the repo
            open GIT, "-|",
                "git", "for-each-ref", "--format=%(refname:short)", $refs
                    or die "Cannot run git-for-each-ref on $repo: $!";
            push @sorted_branches, map { chomp; $_ } <GIT>;
            close GIT;
            die "git-for-each-ref error" if $?;
        } else {
            # Add the branches in the priority order
            push @sorted_branches, split(/\s+/, $refs);
        }
        my @prevbranches;

        # Now get a listing of every committer in those branches
        $ENV{LC_ALL} = "C";
        foreach my $branch (@sorted_branches) {
            open GIT, "-|",
            "git", "log", "-M", "--since=$begin", "--until=$end", "--no-merges",
            ($diffstat ? ( "--shortstat" ) : ()),
            "--pretty=format:%ae %ct %h %p", $branch, @prevbranches,
            "--", "*.cpp", "*.h",
            ":(exclude)Utilities/cmbzip2",
            ":(exclude)Utilities/cmcompress",
            ":(exclude)Utilities/cmcurl",
            ":(exclude)Utilities/cmexpat",
            ":(exclude)Utilities/cmjsoncpp",
            ":(exclude)Utilities/cmlibarchive",
            ":(exclude)Utilities/cmliblzma",
            ":(exclude)Utilities/cmzlib"
                or die("Cannot run git-log on $repo: $!");
            while (<GIT>) {
              commit_begin:
                chomp;
                my ($author, $date, $sha1, @parents) = split / /;
                $author = mapAuthorToAuthor($author);
                my $week = strftime $timeformat, gmtime($date);
                $commits{$week}{$author} = 0
                    unless defined($commits{$week}{$author});
                ++$commits{$week}{$author};
                $branchstats{$week}{$branch} = 0
                    unless defined($branchstats{$week}{$branch});
                ++$branchstats{$week}{$branch};

                next unless $diffstat;
                $_ = <GIT>;
                next unless $_ =~ /^ /;
                chomp;
                next if $_ eq "";
                /(\d+) insertions.* (\d+) deletions/;
                $commitdiffstats{$week}{$author} = 0
                    unless defined $commitdiffstats{$week}{$author};
                my $value = $1;# * 2 + $2;
                if ($value > 5000) {
                    print STDERR "Skipping change ${sha1} because too many lines were changed ($1), repo $repo\n";
                } else {
                    $commitdiffstats{$week}{$author} += $value;
                }

                # eat the empty line
                $_ = <GIT>;
            }
            close GIT;
            die "git-log error" if $?;

            push @prevbranches, "^$branch";
        }
    }
}

sub printCsvStats($) {
    select $csvfh;
    my %commits = %{$_[0]};
    my %activity_per_week;
    my %activity_overall;
    my %total_per_week;
    while (my ($week, $commits) = each %commits) {
        while (my ($author, $count) = each %{$commits}) {
            next if grep { $_ eq $author } @exclude;
            # Author stats
            $activity_per_week{$week}{$author} += $count;
            $activity_overall{$author} += $count;

            # overall stats
            $total_per_week{$week} += $count;
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

    # print unique contributors
    map { print ",\"$_\"" } @sorted_weeks;
    print "\n\"Unique contributors\"";
    map { print ',' . scalar $activity_per_week{$_} } @sorted_weeks;

    select STDOUT;
}

sub printCsvSummary() {
    my %total_per_week;
    my $grand_total;
    while (my ($week, $commits) = each %commits) {
        foreach my $author (@{$commits}) {
            next if grep { $_ eq $author } @exclude;
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
    my $datalabel = $_[1];
    my %commits = %{$_[2]};
    my $datafile = "$gnuplot.$dataname.csv";
    my %activity_per_week;
    my %activity_overall;
    my %total_per_week;
    while (my ($week, $commits) = each %commits) {
        while (my ($author, $count) = each %{$commits}) {
            next if grep { $_ eq $author } @exclude;
            # Author stats
            $activity_per_week{$week}{$author} += $count;
            $activity_overall{$author} += $count;

            # overall stats
            $total_per_week{$week} += $count;
        }
    }

    # sort by decreasing order of activity
    my @sorted_authors;
    if (scalar @_ >= 4) {
        for (reverse @{$_[3]}) {
            push @sorted_authors, $_ if defined($activity_overall{$_});
        }
    } else {
        @sorted_authors =
            sort { $activity_overall{$b} <=> $activity_overall{$a} }
            keys %activity_overall;
    }
    @sorted_authors = @sorted_authors[0 .. $limit - 1]
        if $limit > 0;

    my @sorted_weeks = sort keys %total_per_week;

    my $colcount = scalar @sorted_authors + 3;
    $colcount-- if grep { $_ eq "others" } @exclude and $limit > 0;
    $colcount-- if $limit == 0;

    # write the plot
    select $gnuplotmaster;
    print <<END;
        reset
        set terminal pngcairo size 1400, 600
        set grid front
        set key center below
        set key autotitle columnhead
        set style fill solid
        set format x "%s"
        set rmargin 5
        set ylabel "$datalabel"

        accumulate(c) = column(c) + (c > 3 ? accumulate(c - 1) : 0)
        set style increment
END
    print "set xlabel 'Week'\n" if $mode eq "weekly";
    print "set xlabel 'Month'\n" if $mode eq "monthly";

    # Generate some colours
    my $i = 1;
    for (my $j = 1; $j < 5; $j++) {
        for (qw(255 65280 16711680 65535 16711935 16776960)) {
            my $color = $_;
            $color /= $j;
            $color *= 3 if $j == 4;
            printf "set style line %d linecolor rgb \"#%06X\"\n",
                $i++, $color;
        }
    }

    print <<END;
        set xtics rotate
        set output '$gnuplot.$dataname.total.png'
        plot '$datafile' using 1:(accumulate($colcount)):xticlabels(2) \\
            with filledcurves x1 linecolor 3

        set output '$gnuplot.$dataname.absolute.png'
        plot for [i = $colcount:3:-1] \\
            '$datafile' using 1:(accumulate(i)):xticlabels(2) \\
            title columnhead(i) with filledcurves x1 linestyle i-2

        set output '$gnuplot.$dataname.relative.png'
        set yrange [0:100]
        set format y '%.0f%%'
        plot for [i = $colcount:3:-1] \\
            '$datafile' using 1:(100*accumulate(i)/accumulate($colcount)):xticlabels(2) \\
            title columnhead(i) with filledcurves x1 linestyle i-2

        set output '$gnuplot.$dataname.unique.png'
        set xrange [0.5:*]
        set yrange [0:*]
        set format y "%g"
        set boxwidth 0.9 relative
        set style fill solid 1.0
        set key off
        set ylabel "Contributors"
        plot '-' using 1:3:xticlabels(2) with boxes fillstyle solid lc rgb("#6EBD23")
END

    # write data
    open DATAFILE, ">", $datafile
        or die "Cannot open data file $datafile: $!";
    select DATAFILE;

    print 'idx Week ';
    map { print "\"$_\" "; } @sorted_authors;
    print 'others ' if $limit > 0;
    print "\n";
    $i = 0;
    foreach my $week (@sorted_weeks) {
        my %this_week = %{$activity_per_week{$week}};
        my $total_printed = 0;

        my $label;
        if (scalar @sorted_weeks <= 16
            || ($i % int(scalar @sorted_weeks / 12)) == 0) {
            $label = $week;
        } else {
            $label = "";
        }

        print "$i \"$label\" ";
        print $gnuplotmaster "$i \"$label\" " .
            scalar (keys %this_week) . "\n";

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
    print $gnuplotmaster "e\n\n";
    select STDOUT;
}

my $recurse = 1;
my $printAuthor = 1;
my $printBranches = 0;
my $printEmployer = 1;
my $csv;
while (scalar @ARGV) {
    $_ = shift @ARGV;
    s/^--/-/;
    my $argvalue = 1;
    if (m/^-no-/) {
        s/^-no//;
        $argvalue = 0;
    }
    if (/^-recurse/) {
        $recurse = $argvalue;
    } elsif (/^-author/) {
        $printAuthor = $argvalue;
    } elsif (/^-branches/) {
        $printBranches = $argvalue;
    } elsif (/^-employer/) {
        $printEmployer = $argvalue;
    } elsif (/^-diffstat/) {
        $diffstat = $argvalue;
    } elsif (/^-refs/) {
        $refs = shift @ARGV;
    } elsif (/^-limit/) {
        $limit = shift @ARGV;
    } elsif (/^-csv/) {
        $csv = shift @ARGV;
    } elsif (/^-gnuplot/) {
        $gnuplot = shift @ARGV;
    } elsif (/^-exclude/) {
        push @exclude, shift @ARGV;
    } elsif (/^-since/) {
        $since = shift @ARGV;
    } elsif (/^-mode/) {
        $mode = shift @ARGV;
    } elsif (!/^-/) {
        push @repos, $_;
    }
}

die "Mode must be ''weekly' or 'monthly'"
    unless $mode eq "weekly" or $mode eq "monthly";

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
    # write the secondary data files to "gnuplot.NNN.csv"
    $gnuplot = "gnuplot";
} else {
    open($gnuplotmaster, ">", $gnuplot . ".gnuplot")
        or die "Cannot open output file $csv: $!";
}

my $pwd = `pwd`;
chomp $pwd;
recurseSubmodules() if $recurse;
getAllCommits();
chdir $pwd or die;
my %employerCommits = %{mapToEmployers(\%commits)};
if (defined($csv)) {
    printCsvStats(\%commits) if $printAuthor;
    printCsvStats(\%employerCommits) if $printEmployer;
    printCsvSummary();
}
if (defined($gnuplot)) {
    printGnuplotStats("author", "Commits", \%commits) if $printAuthor;
    printGnuplotStats("employer", "Commits", \%employerCommits)  if $printEmployer;
    printGnuplotStats("volume.author", "Affected lines", \%commitdiffstats)
        if $printAuthor and $diffstat;
    $limit = 0;
    printGnuplotStats("branch", \%branchstats, \@sorted_branches) if $printBranches;
}

# -*- mode: perl; encoding: utf-8; indent-tabs-mode: nil -*-

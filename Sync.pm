package OurNet::BBSApp::Sync;
require 5.006;

$VERSION = '0.8';

use strict;
use integer;

use OurNet::BBS;
use Mail::Address;

use fields qw/artgrp rartgrp param backend logfh msgidkeep hostname/;

sub new {
    my $self = OurNet::BBS::Base::TIEHASH(@_); # save time

    $self->{msgidkeep} ||= 128;
    $self->{logfh}     ||= \*STDIN;
    $self->{hostname}  ||= $OurNet::BBS::Utils::hostname || 'localhost' ;

    return $self;
}

# FIXME: use sorted array and bsearch here.
sub nth {
    my ($ary, $ent) = @_;

    foreach my $i (0 .. $#{@{$ary}}) {
	local $^W;
	return $i if $ary->[$i] eq $ent;
    }

    return -1;
}

sub do_retrack {
    my ($self, $rid, $myid, $low, $high) = @_;
    my $logfh = $self->{logfh};

    return $low - 1 if $low > $high;

    my $try = ($low + $high) / 2;
    my $msgid = eval {$rid->[$try]{header}{'Message-ID'}};

    return (($msgid && nth($myid, $msgid) == -1)
        ? $low-1 : $low) if $low == $high;

    print $logfh ("  [retrack] #$try: try in [$low - $high]\n");

    if ($msgid and nth($myid, $msgid) != -1) {
        return $self->do_retrack($rid, $myid, $try + 1, $high);
    }
    else {
        return $self->do_retrack($rid, $myid, $low, $try - 1)
    }
}

sub retrack {
    my ($self, $rid, $myid, $rseen) = @_;
    my $logfh = $self->{logfh};

    print $logfh ("  [retrack] #$rseen: checking\n");

    return $rseen 
	if eval {$rid->[$rseen]{header}{'Message-ID'}} eq $myid->[-1];

    $self->do_retrack(
	$rid, 
	$myid, 
	($rseen > $self->{msgidkeep}) 
	    ? $rseen - $self->{msgidkeep} : 0, 
	$rseen-1
    );
}

sub do_send {
    my $self = $_[0];
    my $artgrp  = $self->{artgrp};
    my $rartgrp = $self->{rartgrp};
    my $param   = $self->{param};
    my $backend = $self->{backend};
    my $logfh   = $self->{logfh};
    my $lseen   = $param->{lseen};
    return unless $lseen eq int($lseen || 0); # must be int

    print $logfh ("     [send] checking...\n");

    # XXX voodoo witch doctor style preload
    my $art      = $artgrp->[1] if ($#{@$artgrp});
    my $rbrdname = $param->{board};

    $lseen = $#{@$artgrp} if $#{@$artgrp} < $lseen;

    if ($param->{lmsgid}) { # backtrace
	++$lseen;

	while (--$lseen > 0) {
	    $art = eval { $artgrp->[$lseen] } or next;

	    print $logfh ("     [send] #$lseen: backtracing\n");
	    last unless $art->{header}{From} =~ m/\./ 
		or $param->{lmsgid} lt $art->{header}{'Message-ID'};
	}

        $param->{lseen} = $lseen;
    }

    while ($lseen++ < $#{@$artgrp}) {
        my $art = eval { $artgrp->[$lseen] } or next;

        next unless (
	    index(($art->{header}{'X-Originator'} || ''),  
		  "$rbrdname.board\@$param->{remote}") == -1
	    and ($backend ne 'NNTP' or !$art->{header}{Path})
	);
	print $logfh ("     [send] #$lseen: posting $art->{title}\n");

	my %xart = (header => { %{$art->{header}} });
	safe_copy($art, \%xart);

	my $adr = (Mail::Address->parse($xart{header}{From}))[0];

	$xart{header}{From} = (
	    $adr->address.'@'.$self->{hostname}.' '.$adr->comment
	) if $adr;

	my $xorig = $artgrp->board.'.board@'.$self->{hostname};

	if ($backend eq 'NNTP') {
	    $xart{header}{'X-Originator'} = $xorig;
	}
	else {
	    $xart{body} .= "\n---\nX-Originator: $xorig";
	}
	eval { $rartgrp->{''} = \%xart };
	unless ($@) {
	    $param->{lseen}  = $lseen;
	    $param->{lmsgid} = $art->{header}{'Message-ID'};
	}
	else {
	    print $logfh ("     [send] #$lseen: can't post $@\n");
	}
    }

    return 1;
}

sub do_fetch {
    my $self = $_[0];
    my $artgrp  = $self->{artgrp};
    my $rartgrp = $self->{rartgrp};
    my $param   = $self->{param};
    my $backend = $self->{backend};
    my $logfh   = $self->{logfh};

    my ($first, $last, $rseen);
    my $rbrdname = $rartgrp->board(); # remote board name

    if ($backend eq 'NNTP') {
	$first	= $rartgrp->first;
	$last	= $rartgrp->last;
	$rseen	= $param->{rseen} || ($last - $self->{msgidkeep});
    }
    else {
	$first	= 1; # for normal sequential backends
	$last	= $#{$rartgrp};
	$rseen	= $param->{rseen};
    }

    $rseen += $last if $rseen < 0;      # negative subscripts
    $rseen = $last  if $rseen > $last;  # upper bound

    return unless defined($rseen) and length($rseen); # requires rseen

    print $logfh "    [fetch] #$param->{rseen}: checking\n";

    if ($#{$param->{msgids}} >= 0) {
	$rseen = $self->retrack($rartgrp, $param->{msgids}, $rseen)
	    if $rseen and eval {
		$rartgrp->[$rseen]{header}{'Message-ID'}
	    } ne $param->{msgids}[-1];
    }
    else { # init
	my $rfirst = (($rseen - $first) > $self->{msgidkeep}) 
	    ? $rseen - $self->{msgidkeep} : $first;

        my $i = $rfirst;

        while($i <= $rseen) {
            print $logfh "    [fetch] #$i: init";

	    eval {
		my $art = $rartgrp->[$i++];
		$art->refresh();
		push @{$param->{msgids}}, $art->{header}{'Message-ID'};
	    };

            print $logfh $@ ? " failed: $@\n" : " ok\n";
        }

        $rseen = $i - 1;
    }

    print $logfh ($rseen < $last)
	? "    [fetch] range: ".($rseen+1)."..$last\n"
	: "    [fetch] nothing to fetch ($rseen >= $last)\n";

    while ($rseen < $last) {
        my $art;

        print $logfh "    [fetch] #".($rseen+1).": reading";

	eval {
	    $art = $rartgrp->[$rseen+1];
	    $art->refresh();
	};

	if ($@) {
            print $logfh "... nonexistent, failed\n";
	    ++$rseen; next;
        }

	my $xorig = $artgrp->board.'.board@'.$self->{hostname};
	my $rhead = $art->{header};

	if (
	    index($art->{body}, "X-Originator: $xorig") == -1 and
	    nth($param->{msgids}, $rhead->{'Message-ID'}) == -1 and
		($rhead->{'X-Originator'} || '') ne $xorig
	) {
	    push @{$param->{msgids}}, $rhead->{'Message-ID'};

	    my %xart = (header => $rhead); # maximal cache
	    safe_copy($art, \%xart);

	    $xart{header}{Board} = $artgrp->board; 
	    $xart{header}{'X-Originator'} = 
		"$rbrdname.board\@$param->{remote}" if $backend ne 'NNTP';

	    if ($param->{backend} eq 'BBSAgent') {
		$xart{body} =~ s/\x1b\[[\d;]*m//g;
		$xart{body} =~ s|^((?:: )+)|'> ' x (length($1)/2)|meg;
	    }

            $xart{body}   ||= "\n";
            $xart{title}  ||= " ";
            $xart{author} ||= "(nobody)."; # for sanity's sake

            $artgrp->{''} = \%xart;

            print $logfh (" $xart{title}\n");
        }
        else {
            print $logfh ("... duplicate, skipped\n");
	    push @{$param->{msgids}}, $art->{header}{'Message-ID'};
        }

	++$rseen;
    }

    $param->{rseen} = $rseen;

    return 1;
}

sub safe_copy {
    my ($from, $to) = @_;

    while (my ($k, $v) = each (%{$from})) {
	$to->{$k} = $v if index(
	    ' name header id xmode time mtime ', " $k "
	) == -1;
    }
}

1;

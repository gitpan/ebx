# $File: //depot/ebx/Sync.pm $ $Author: autrijus $
# $Revision: #60 $ $Change: 1464 $ $DateTime: 2001/07/18 01:54:06 $

package OurNet::BBSApp::Sync;
require 5.006;

$VERSION = '0.84';

use strict;
use integer;

use IO::Handle;
use Mail::Address;
use OurNet::BBS;

=head1 NAME

OurNet::BBSApp::Sync - Sync between BBS article groups

=head1 SYNOPSIS

    my $sync = OurNet::BBSApp::Sync->new({
        artgrp      => $local->{boards}{board1}{articles},
        rartgrp     => $remote->{boards}{board2}{articles},
        param       => {
	    lseen   => 0,
	    rseen   => 0,
	    remote  => 'bbs.remote.org',
	    backend => 'BBSAgent',
	    board   => 'board2',
	    lmsgid  => '',
	    msgids  => [
		'<20010610005743.6c+7nbaJ5I63v5Uq3cZxZw@geb.elixus.org>',
		'<20010608213307.suqAZQosHH7LxHCXVi1c9A@geb.elixus.org>',
            ]
        },
        force_fetch => 0,
	force_send  => 0,
	force_none  => 0,
	recursive   => 0,
	clobber	    => 1,
        backend     => 'BBSAgent',
        logfh       => \*STDOUT,
    });

    $sync->do_fetch;
    $sync->do_send;

=head1 DESCRIPTION

L<OurNet::BBSApp::Sync> performs a sophisticated synchronization heuristic
on two L<OurNet::BBS> ArticleGroup objects. It operates on the first one
(C<lartgrp>)'s behalf, updates what's being done in the C<param> field, 
and attempts to determine the minimally needed transactions to run.

The two methods, L<do_fetch> and L<do_send> could be used independently.
Beyond that, note that the interface might change in the future, and
currently it's only a complement to the L<ebx> toolkit.

=head1 BUGS

Lots. Please report bugs as much as possible.

=cut

use fields qw/artgrp rartgrp param backend logfh msgidkeep hostname
              force_send force_fetch force_none clobber recursive/;

use constant SKIPPED_HEADERS =>
    ' name header xid id xmode idxfile time mtime btime basepath'.
    ' dir hdrfile recno ';
use constant SKIPPED_SIGILS => ' ¡» ¡· ¡º ';

sub new {
    my $self = OurNet::BBS::Base::TIEHASH(@_); # save time

    $self->{msgidkeep} ||= 128;
    $self->{hostname}  ||= $OurNet::BBS::Utils::hostname || 'localhost';
    $self->{logfh}     ||= IO::Handle->new->fdopen(fileno(STDOUT), 'w');
    $self->{logfh}->autoflush(1);

    return $self;
}

# FIXME: use sorted array and bsearch here.
sub nth {
    my ($ary, $ent) = @_;

    no warnings 'uninitialized';

    foreach my $i (0 .. $#{@{$ary}}) {
	return $i if $ary->[$i] eq $ent;
    }

    return -1;
}

sub do_retrack {
    my ($self, $rid, $myid, $low, $high) = @_;
    my $logfh = $self->{logfh};

    return $low - 1 if $low > $high;

    my $try = ($low + $high) / 2;
    my $msgid = eval {
	my $art = $rid->[$try];
	UNIVERSAL::isa($art, 'UNIVERSAL') 
	    ? $art->{header}{'Message-ID'} : undef;
    };

    return (($msgid && nth($myid, $msgid) == -1)
        ? $low - 1 : $low) if $low == $high;

    $logfh->print("  [retrack] #$try: try in [$low - $high]\n");

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

    $logfh->print("  [retrack] #$rseen: checking\n");

    return $rseen if (eval {
	$rid->[$rseen]{header}{'Message-ID'}
    } || '') eq $myid->[-1];

    $self->do_retrack(
	$rid, 
	$myid, 
	($rseen > $self->{msgidkeep}) 
	    ? $rseen - $self->{msgidkeep} : 0, 
	$rseen - 1
    );
}

sub do_send {
    my $self     = $_[0];
    my $artgrp   = $self->{artgrp};
    my $rartgrp  = $self->{rartgrp};
    my $param    = $self->{param};
    my $backend  = $self->{backend};
    my $logfh    = $self->{logfh};
    my $lseen    = $param->{lseen};
    my $rbrdname = $param->{board};

    return unless $lseen eq int($lseen || 0); # must be int
    $lseen = $#{@$artgrp} if $#{@$artgrp} < $lseen;

    $logfh->print("     [send] checking...\n");

    if ($param->{lmsgid}) { # backtrace
	++$lseen;

	while (--$lseen > 0) {
	    my $art = eval { $artgrp->[$lseen] } or next;

	    $logfh->print("     [send] #$lseen: backtracing\n");
	    last unless $param->{lmsgid} lt $art->{header}{'Message-ID'};
	}

        $param->{lseen} = $lseen;
    }

    return if ($lseen >= $#{$artgrp});

    while ($lseen++ < $#{$artgrp}) {
        my $art = eval { $artgrp->[$lseen] } or next;
        next unless defined $art->{title}; # sanity check

        next unless (
	    $self->{force_send} or (
		index(($art->{header}{'X-Originator'} || ''),  
		    "$rbrdname.board\@$param->{remote}") == -1 and
		($backend ne 'NNTP' or !$art->{header}{Path})
	    )
	);

	$logfh->print("     [send] #$lseen: posting $art->{title}\n");

	my %xart = ( header => { %{$art->{header}} } );
	safe_copy($art, \%xart);

	if ($self->{clobber}) {
	    my $adr = (Mail::Address->parse($xart{header}{From}))[0];

	    $xart{header}{From} = (
		$adr->address.'@'.$self->{hostname}.' '.$adr->comment
	    ) if $adr;
	}

	my $xorig = $artgrp->board.'.board@'.$self->{hostname};

	if (index(' NNTP MELIX DBI ', $backend) > -1
	    or ($backend eq 'OurNet' 
	        and index(' NNTP MELIX DBI ', $rartgrp->backend) > -1))
	{
	    $xart{header}{'X-Originator'} = $xorig;
	}
	elsif (rindex($xart{body}, "--\n¡°") > -1) {
	    chomp($xart{body});
	    chomp($xart{body});
	    $xart{body} .= "\n¡° X-Originator: $xorig";
	}
	else {
	    $xart{body} .= "--\n¡° X-Originator: $xorig";
	}

	eval { $rartgrp->{''} = \%xart } unless $self->{force_none};

	if ($@) {
	    chomp(my $error = $@);
	    $logfh->print("     [send] #$lseen: can't post ($error)\n");
	}
	else {
	    $param->{lseen}  = $lseen;
	    $param->{lmsgid} = $art->{header}{'Message-ID'};
	}
    }

    return 1;
}

sub do_fetch {
    my $self	= $_[0];
    my $artgrp	= $self->{artgrp};
    my $rartgrp	= $self->{rartgrp};
    my $param	= $self->{param};
    my $backend	= $self->{backend};
    my $logfh	= $self->{logfh};

    my ($first, $last, $rseen);
    my $rbrdname = $rartgrp->board; # remote board name

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

    return unless defined($rseen) and length($rseen); # requires rseen

    $rseen += $last if $rseen < 0;      # negative subscripts
    $rseen = $last  if $rseen > $last;  # upper bound

    $logfh->print("    [fetch] #$param->{rseen}: checking\n");

    if ($#{$param->{msgids}} >= 0) {
	if ($rseen and my $msgid = eval {
	    $rartgrp->[$rseen]{header}{'Message-ID'}
	}) {
	    $msgid = "<$msgid>" if substr($msgid, 0, 1) ne '<';
	    $rseen = $self->retrack($rartgrp, $param->{msgids}, $rseen)
	        if $msgid ne $param->{msgids}[-1];
	}
    }
    else { # init
	my $rfirst = (($rseen - $first) > $self->{msgidkeep}) 
	    ? $rseen - $self->{msgidkeep} : $first;

        my $i = $rfirst;

        while($i <= $rseen) {
            $logfh->print("    [fetch] #$i: init");

	    eval {
		my $art = $rartgrp->[$i++];
		$art->refresh;
		push @{$param->{msgids}}, $art->{header}{'Message-ID'};
	    };

            $logfh->print($@ ? " failed: $@\n" : " ok\n");
        }

        $rseen = $i - 1;
    }

    $rseen = 0 if $rseen < 0;

    $logfh->print(
	($rseen < $last)
	    ? "    [fetch] range: ".($rseen+1)."..$last\n"
	    : "    [fetch] nothing to fetch ($rseen >= $last)\n"
    );

    return if $rseen >= $last;

    my $xorig = $artgrp->board.".board\@$self->{hostname}";

    while ($rseen < $last) {
        my $art;

        $logfh->print("    [fetch] #".($rseen+1).": reading");

	eval { 
	    $art = $rartgrp->[$rseen+1];
	    $art->refresh;
	};

	if ($@) {
            $logfh->print("... nonexistent, failed\n");
	    ++$rseen; next;
        }

	my ($msgid, $rhead);

	if ($art->REF =~ m|ArticleGroup|) {
	    # not really a message so won't have MSGID; let's fake one here.
	    my $time = $art->mtime;

	    $art = {
		title  => $art->{title},
		author => $art->{author},
	    };

	    $msgid = OurNet::BBS::Utils::get_msgid(
		$time,
		$art->{author},
		$art->{title},
		$rbrdname,
		$param->{remote},
	    );
	}
	else {
	    $msgid = $art->{header}{'Message-ID'}; # XXX voodoo refresh

	    $art = $art->SPAWN;
	    $rhead = $art->{header};

	    if ($rhead->{'Message-ID'} ne $msgid) {
		# something's very, very wrong
		print "... lacks Message-ID, skipped\n";
		++$rseen; next;
	    }

	    $msgid = "<$msgid>" if substr($msgid, 0, 1) ne '<'; # legacy
	}

	if ($self->{force_fetch} or
	    rindex($art->{body}, "X-Originator: $xorig") == -1 and
	    nth($param->{msgids}, $msgid) == -1 and
		($rhead->{'X-Originator'} || '') ne $xorig
	) {
	    push @{$param->{msgids}}, $msgid;

	    my (%xart, $xartref);

	    if ($rhead->{'Message-ID'}) {
		%xart = (header => $rhead); # maximal cache
		safe_copy($art, $xartref = \%xart);

		# the code below makes us *really* want a ??= operator.
		unless (defined $xart{body} and 
		        defined $xart{header}{Subject}) {
		    print "... article empty, skipped\n";
		    ++$rseen; next;
		}

		$xart{header}{'X-Originator'} = 
		    "$rbrdname.board\@$param->{remote}" if $backend ne 'NNTP';

		$xart{body} =~ s|^((?:: )+)|'> ' x (length($1)/2)|gem;
		$xart{nick} = $1 if $xart{nick} =~ m/^\s*\((.*)\)$/;

		if ($self->{clobber} and $backend ne 'NNTP') {
		    $xart{author} .= "." unless !$xart{author}
			or substr($xart{author}, -1) eq '.';
		    $xart{header}{From} = 
			"$xart{author}bbs\@$param->{remote}" . 
			($xart{nick} ? " ($xart{nick})" : '')
			    unless $xart{header}{From} =~ /^[^\(]+\@/;
		}
		elsif (0) { # XXX: not yet supported
		    $xart{header}{'Reply-To'} = 
			"$xart{author}.bbs\@$param->{remote}" . 
			(defined $xart{nick} ? " ($xart{nick})" : '')
			    unless $xart{header}{From} =~ /^[^\(]+\@/;
		}

		$artgrp->{''} = $xartref unless $self->{force_none};
		$logfh->print(" $xart{title}\n");
	    }
	    else { # ArticleGroup code
		%xart = %{$art};

		# strip down unnecessary sigils
		$xart{title} = substr($xart{title}, 3)
		    if index(SKIPPED_SIGILS, substr($xart{title}, 0, 3)) > -1;

		$xartref = bless(\%xart, $artgrp->module('ArticleGroup'));

		$artgrp->{''} = $xartref unless $self->{force_none};
		$logfh->print(" $xart{title}\n");

		if ($self->{recursive}) {
		    $self->{artgrp}  = $artgrp->[-1];
		    $self->{artgrp}  = $artgrp->[-1];
		    $self->{rartgrp} = $art = $rartgrp->[$rseen+1];
		    $self->do_fetch;
		    $self->{artgrp}  = $artgrp;
		    $self->{rartgrp} = $rartgrp;
		}
	    }

        }
        else {
            $logfh->print("... duplicate, skipped\n");
	    push @{$param->{msgids}}, $msgid;
        }

	++$rseen;
    }

    $param->{rseen} = $rseen;

    return $artgrp->[-1] || 1; # must be here to re-initialize this board
}

sub safe_copy {
    my ($from, $to) = @_;

    while (my ($k, $v) = each (%{$from})) {
	$to->{$k} = $v if index(
	    SKIPPED_HEADERS, " $k "
	) == -1;
    }
}

1;

__END__

=head1 SEE ALSO

L<ebx> -- The Elixir BBS Exchange Suite.

=head1 AUTHORS

Chia-Liang Kao E<lt>clkao@clkao.org>,
Autrijus Tang E<lt>autrijus@autrijus.org>

=head1 COPYRIGHT

Copyright 2001 by Chia-Liang Kao E<lt>clkao@clkao.org>,
                  Autrijus Tang E<lt>autrijus@autrijus.org>.

All rights reserved.  You can redistribute and/or modify
this module under the same terms as Perl itself.

=cut

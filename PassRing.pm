# $File: //depot/ebx/PassRing.pm $ $Author: autrijus $
# $Revision: #9 $ $Change: 1120 $ $DateTime: 2001/06/13 11:27:23 $

package OurNet::BBSApp::PassRing;

$VESION = '0.3';

use strict;

use IO::Handle;
use GnuPG::Interface;
use Storable qw/freeze thaw/;
use fields qw/gnupg keyfile who/;

sub new {
    my ($class, $keyfile, $who) = @_;
    my $self = fields::new($class);
    my $gpg  = $self->{gnupg} = GnuPG::Interface->new();

    $self->{keyfile} = $keyfile;
    $self->{who}     = $who;

    $gpg->options->hash_init( armor => 0, always_trust => 1);
    $gpg->options->meta_interactive( 0 );
    $gpg->options->push_recipients($self->{who});
    
    return $self;
}

sub get_keyring {
    my ($self, $pass) = @_;

    return thaw(scalar( 
	`echo $pass| gpg -d --no-tty --passphrase-fd=0 $self->{keyfile}`
    )) if $^O eq 'cygwin'; # XXX: kludge, fixme.

    local $/;
    return unless -e $self->{keyfile};
    open KEY, $self->{keyfile} 
	or die "can't open keyfile $self->{keyfile}: $!";

    my ( $input, $output, $stderr, $passphrase_fd )
           = ( IO::Handle->new(),
               IO::Handle->new(),
	       IO::Handle->new(),
               IO::Handle->new());

    my $handles = GnuPG::Handles->new( 
	stdin      => $input,
	stdout     => $output,
	stderr     => $stderr,
	passphrase => $passphrase_fd,
    );

    my $pid = $self->{gnupg}->decrypt( handles => $handles );

    # Now we write to the input of GnuPG
    print $passphrase_fd $pass;
    close $passphrase_fd;

    my $buf = <KEY>;
    print $input $buf;
    close $input;

    # now we read the output
    my $plaintext = <$output>;
    close $output;

    my $err = <$stderr>;
    close $stderr;

    waitpid $pid, 0;
    close KEY;

    return thaw($plaintext);
}

sub save_keyring {
    my ($self, $keyring) = @_;

    my ( $input, $output, $stderr )
           = ( IO::Handle->new(),
	       IO::Handle->new(),
               IO::Handle->new());

    my $handles = GnuPG::Handles->new( 
	stdin  => $input,
	stdout => $output,
	stderr => $stderr,
    );

    my $pid = $self->{gnupg}->encrypt( handles => $handles );

    print $input freeze($keyring);
    close $input;

    local $/;
    open KEY, ">$self->{keyfile}" 
	or die "can't write keyfile $self->{keyfile}: $!";
    my $ci = <$output>;
    close $output;

    waitpid $pid, 0;
    print KEY $ci;
    close KEY; 
}

1;

# $File: //depot/ebx/PassRing.pm $ $Author: autrijus $
# $Revision: #15 $ $Change: 1512 $ $DateTime: 2001/08/06 21:36:32 $

package OurNet::BBSApp::PassRing;

$VESION = '0.4';

use strict;

use IO::Handle;
use Storable qw/nfreeze thaw nstore retrieve/;
use fields qw/gnupg passphrase keyfile who/;
use open IN => ':raw', OUT => ':raw';

# XXX: Win32 GnuPG::Interface is *absolutely* broken!
# XXX: we might need to use symmetric key, say Crypt::* here.

if ($^O eq 'MSWin32') {
    *POSIX::F_SETFD       = sub { 2 };
    *POSIX::STDERR_FILENO = sub { 2 };
    *POSIX::STDOUT_FILENO = sub { 1 };
    *POSIX::STDIN_FILENO  = sub { 0 };
}

sub new {
    my ($class, $keyfile, $who) = @_;
    my $self = fields::new($class);

    $self->{keyfile} = $keyfile;
    $self->{who}     = $who;

    return $self;
}

sub init_gnupg {
    my $self = shift;

    require GnuPG::Interface;

    my $gpg  = $self->{gnupg} = GnuPG::Interface->new();

    $gpg->options->hash_init(
	armor	     => 0, 
	always_trust => 1,
    );
    $gpg->options->meta_interactive(0);
    $gpg->options->push_recipients($self->{who});
}

sub get_keyring {
    my ($self, $pass) = @_;
    $self->{passphrase} = $pass if defined $pass;

    my $frozen;

    open my $keyfile, $self->{keyfile};
    read($keyfile, $frozen, 3);
    close $keyfile;

    $frozen = $frozen eq 'pst' ? retrieve($self->{keyfile}) : {};

    my $cipher = $frozen->{cipher} ||= 'GnuPG'; # for bugward compatibility

    return $self->thaw_rijndael($frozen) if $cipher eq 'Rijndael';
    return $self->thaw_gnupg($frozen)    if $cipher eq 'GnuPG';
}

sub thaw_rijndael {
    my ($self, $frozen) = @_;

    require Crypt::Rijndael;
    require Digest::MD5;

    return thaw(Crypt::Rijndael->new(
	Digest::MD5::md5_hex($self->{passphrase}),
	&Crypt::Rijndael::MODE_CBC,
    )->decrypt($frozen->{data}));
}

sub thaw_gnupg {
    my ($self, $frozen) = @_;

    return thaw(scalar( 
	`echo $self->{passphrase} | gpg -d --no-tty --passphrase-fd=0 $self->{keyfile}`
    )) if $^O eq 'cygwin'; # XXX: kludge, fixme.

    local $/;
    return unless -e $self->{keyfile};

    open KEY, $self->{keyfile} 
	or die "can't open keyfile $self->{keyfile}: $!";

    $self->init_gnupg;

    my ($input, $output, $stderr, $passphrase_fd) = ( 
	IO::Handle->new,
	IO::Handle->new,
	IO::Handle->new,
	IO::Handle->new,
    );

    my $handles = GnuPG::Handles->new( 
	stdin      => $input,
	stdout     => $output,
	stderr     => $stderr,
	passphrase => $passphrase_fd,
    );

    my $pid = $self->{gnupg}->decrypt( handles => $handles );

    # Now we write to the input of GnuPG
    print $passphrase_fd $self->{passphrase};
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

sub store_rijndael {
    my ($self, $keyring) = @_;
    my $frozen = nfreeze($keyring);
    $frozen .= "\x00" x ((32 - length($frozen) % 32) % 32);

    require Digest::MD5;
    require Crypt::Rijndael;

    nstore({
	data	=> Crypt::Rijndael->new(
	    Digest::MD5::md5_hex($self->{passphrase}),
	    &Crypt::Rijndael::MODE_CBC,
	)->encrypt($frozen),
	cipher	=> 'Rijndael'
    }, $self->{keyfile});
}

sub save_keyring {
    my ($self, $keyring, $cipher) = @_;
    $cipher ||= 'Rijndael';

    return $self->store_rijndael($keyring) if $cipher eq 'Rijndael';
    return $self->store_gnupg($keyring)    if $cipher eq 'GnuPG';
}

sub store_gnupg {
    my ($self, $keyring) = @_;

    $self->init_gnupg;

    my ($input, $output, $stderr) = ( 
	IO::Handle->new,
	IO::Handle->new,
	IO::Handle->new,
    );

    my $handles = GnuPG::Handles->new( 
	stdin  => $input,
	stdout => $output,
	stderr => $stderr,
    );

    my $pid = $self->{gnupg}->encrypt( handles => $handles );

    print $input nfreeze($keyring);
    close $input;

    local $/;
    open(my $KEY, '>', $self->{keyfile}) 
	or die "can't write keyfile $self->{keyfile}: $!";
    my $ci = <$output>;
    close $output;

    waitpid $pid, 0;
    print $KEY $ci;
    close $KEY; 
}

1;


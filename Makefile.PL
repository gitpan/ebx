#!/usr/bin/perl

require 5.005;

use ExtUtils::MakeMaker;

WriteMakefile(
    AUTHOR          => 'Autrijus Tang (autrijus@autrijus.org)',
    ABSTRACT        => 'Elixir BBS Exchange Suite',
    NAME            => 'OurNet::BBSApp::Sync',
    VERSION_FROM    => 'ebx',
    DISTNAME        => 'ebx',
    BINARY_LOCATION => 'x86/ebx.tar.gz',

    PREREQ_PM       => {
	'OurNet::BBS'		=> '1.53',       # BBSApp
	'Mail::Address'         => '1.17',       # Sync
	'GnuPG::Interface'      => '0.31',       # PassRing
	'Term::ReadKey'		=> '2.14',       # ebx
	'MIME::Base64'		=> '2.11',       # ebx
	'Compress::Zlib'	=> '1.08',       # ebx
	'Getopt::Std'		=> '1.02',       # ebx
	'Storable'		=> '1.011',      # ebx
    },
	
    EXE_FILES       => [ 'ebx' ],

    dist            => {
	COMPRESS    => 'gzip',
	SUFFIX      => '.gz',
    }
);


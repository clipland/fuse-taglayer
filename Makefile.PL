

use ExtUtils::MakeMaker;

rename('README.md','README') if -f 'README.md';

WriteMakefile(
	NAME		=> 'Fuse::TagLayer',
	AUTHOR		=> 'Clipland (clipland@cpan.org)',
	ABSTRACT	=> 'Tag-filesystem overlay for hierarchical fs',
	VERSION_FROM	=> 'lib/Fuse/TagLayer.pm', # finds \$VERSION
	LICENSE		=> 'gpl', # as close as it gets to GPL3+AL2
	PREREQ_PM	=> {
		"Fuse"		=> '0.14',
		"File::ExtAttr"	=> '1.09',
		"Data::Dumper"	=> 0,
		"DBI"		=> 0,
		"File::Find"	=> 0,
		"File::Basename"=> 0,
		"Fcntl"		=> 0,
		"POSIX"		=> 0,
		"Getopt::Long"	=> 0,
		"Pod::Usage"	=> 0,
	},
	EXE_FILES	=> [
		'bin/taglayer'
	],
	META_MERGE	=> {
		resources	=> {
			repository => 'https://github.com/clipland/fuse-taglayer',
		},
	},
	dist => {
		POSTOP => 'perl -e "rename(\'README\',\'README.md\') if -f \'README\'"',
	},
	realclean => {
		POSTOP => 'perl -e "rename(\'README\',\'README.md\') if -f \'README\'"',
	},
);

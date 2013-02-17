package Fuse::TagLayer;

# use strict;
use warnings;

use Data::Dumper;
use DBI;
use File::ExtAttr ();
use File::Find ();
use File::Basename ();
use Fcntl qw(SEEK_SET);
use POSIX qw(S_ISDIR ENOENT EISDIR EINVAL ENOSYS);

our $VERSION = '0.10';
our $self;

sub new {
	my $class = shift;

	$self = bless({
		@_
	}, $class);

	$self->{uid} ||= 0;
	$self->{gid} ||= 0;

	print "TagLayer: Building TagLayer tags database...\n" if $self->{debug};
	init_db();	## init db (SQLite)

	## prepare a mysql insert statement
	$self->{mysql_file_insert} = database()->prepare("INSERT INTO `file_tags` (`file`,`basename`,`tags`) VALUES (?,?,?); ") or die database()->errstr;
	$self->{mysql_tags_insert} = database()->prepare("INSERT INTO `tags` (`tag`,`count`) VALUES (?,?); ") or die database()->errstr;

	## prepare a mountpoint regex
	my $mntre = quotemeta($self->{mountpoint});
	$self->{mountpoint_regex} = qr/^$mntre/;

	## build SQL tables
	# table:file_tags
	database()->{AutoCommit} = 0;
	File::Find::find({ wanted => \&wanted }, $self->{realdir});
	database()->commit;

	# table:tags
	for (keys %{ $self->{global_tags} }){
#		print "$_, ". $self->{global_tags}->{$_} ." \n" if $self->{debug};
		$self->{mysql_tags_insert}->execute($_, $self->{global_tags}->{$_}) or die database()->errstr;

		$self->{tags_cnt}++;
		database()->commit if $self->{tags_cnt} && ($self->{tags_cnt} % 250) == 0;
	}
	delete($self->{global_tags});
	database()->commit;
	database()->{AutoCommit} = 1;

	$self->{db_epoch} = time();

	print "TagLayer: processed ".($self->{files_cnt}||0)." files with ".($self->{tags_cnt}||0)." tags.\n" if $self->{debug};

	return $self;
}

sub init_db {
	my $sql = "create table if not exists `tags` (
		`tag` varchar(255) null,
		`count` integer DEFAULT '0'
	);";
	database()->do($sql) or die database()->errstr;
	my $empty = database()->prepare("DELETE FROM `tags`; ") or die database()->errstr;	# no TRUNCATE TABLE in SQLite
	$empty->execute();

	$sql = "create table if not exists `file_tags` (
		`file` varchar(255) null,
		`basename` varchar(255) null,
		`tags` varchar(255) null
	);";
	database()->do($sql) or die database()->errstr;
	my $empty2 = database()->prepare("DELETE FROM `file_tags`; ") or die database()->errstr;	# no TRUNCATE TABLE in SQLite
	$empty2->execute();
}

sub database {
	unless($self->{dbh}){
		$self->{dbh} = DBI->connect("dbi:SQLite::memory:", "", "");
	#	$self->{dbh} = DBI->connect("dbi:SQLite:dbname=/tmp/taglayer.sqlite", "", "");	# for debug only, make sure you delete the file after each mount!!
	}
	return $self->{dbh};
}

sub mount {
	my $self = shift;

	print '## TagLayer: mount() self:'.Dumper($self) if $self->{debug};

	## check local mount point
	if(!-d $self->{mountpoint}){
		die 'Fuse::TagLayer: Mountpoint '.$self->{mountpoint}.' does not exists!';
	}

	Fuse::main(
		mountpoint => $self->{mountpoint},
		threaded   => $self->{threaded} ? 1 : 0,
		debug	   => $self->{debug} > 1 ? 1 : 0,

		readdir	=> "Fuse::TagLayer::virt_readdir",
		getattr	=> "Fuse::TagLayer::virt_getattr",
		open	=> "Fuse::TagLayer::real_open",
		read	=> "Fuse::TagLayer::real_read",
		release	=> "Fuse::TagLayer::real_release",
		statfs	=> "Fuse::TagLayer::virt_statfs",
	);
	return;
}

sub dirpath_to_tags {
	## explode path into tags
	# if path comes from wanted, it returns unclean "tags",
	# if path comes from our paths, tags should already be cleaned

	my @pathtags = split(/\//,shift);
	shift(@pathtags); # root path means no dirtags

	return @pathtags;
}

sub wanted {
	## if our mountpoint is within the realdir, ignore ourself
	return if $File::Find::dir =~ $self->{mountpoint_regex};

	## only dirs with files qualify
	return if !-f $File::Find::name;

	my $realdir = $self->{realdir};
	my $rel_dir = $File::Find::dir;
	$rel_dir =~ s/^$realdir//;

	my @tags;
	## dir tags
	@tags = dirpath_to_tags($rel_dir) unless $self->{no_tags_from_path};

	if($self->{more_tags}){
		my $filename = lc($_);
		$filename =~ s/(\.[a-zA-Z0-9]{2,5})$//;
		if(my $suffix = $1){
			$suffix =~ s/jpeg/jpg/;
			push(@tags, 'zsuffix-'.$suffix);
		}

		push(@tags, split(/[^\p{L}\p{N}]/,$filename));	# matches all (Unicode) characters that are neither letters nor numbers
	}

	## xattr tags
	if(!$self->{no_tags_from_xattr}){
		if(my $xattrtags = File::ExtAttr::getfattr( $File::Find::dir.'/'.$_, 'tags') ){
			push(@tags, split(/,\s*/,$xattrtags));
		}
	}

	# clean and dedup, as there might be duplicates after cleansing
	my %tags;
	for(@tags){
		my $tag_cleaned = lc($_);
		$tag_cleaned =~ s/[^\p{L}\p{N}]//g;	# matches all (Unicode) characters that are neither letters nor numbers
		next if length($tag_cleaned) < 2;
		$tags{$tag_cleaned}++;

		$self->{global_tags}->{$tag_cleaned}++;
	}

	# insert "/path/to", "filename", "tags as csv string"
	$self->{mysql_file_insert}->execute( $File::Find::dir, $_, join(", ", keys %tags) ) or die database()->errstr;
	$self->{files_cnt}++;
#	print "File: $self->{files_cnt}: $File::Find::dir, $_, ".join(", ", keys %tags)."\n";

	if($self->{files_cnt} && ($self->{files_cnt} % 250) == 0){
		database()->commit;
		print " $self->{files_cnt} files processed\n" if $self->{debug};
	}
}

## note the singular "file", as it should return only one file
sub file_by_tagpath {
	my ($basename,$directory) = File::Basename::fileparse(shift);
# print "Directory:$directory Basename:$basename\n";
	# 1st: only by tags
	my @tags = dirpath_to_tags($directory);

	return undef if !@tags;

	my @sql_files;
	for(@tags){
		push(@sql_files, "`tags` REGEXP '$_'");
	}
	my $sql_files = join(" AND ",@sql_files);

# print "PREFAIL: tags: @tags (".@tags.") ;; SELECT `file`,`basename` FROM `file_tags` WHERE $sql_files;\n";
	my $pre = database()->selectall_arrayref("SELECT `file`,`basename` FROM `file_tags` WHERE $sql_files; ", {Columns=>[1,2]}); # push first two rows into arrayref

	return undef if !@$pre;

	# 2nd: by basename
	my @files;
	for(@$pre){
		push(@files, ${$_}[0].'/'.${$_}[1]) if ${$_}[1] eq $basename;
	}

	print "++ WARNING ++ file_by_tagpath($basename,@_) found multiple files: @files\n" if @files > 1;

	return @files ? shift(@files) : undef;
}

sub virt_readdir {
	my ($path,$offset) = @_;

	my (@dirs,@files);
	if($path eq '/'){
		## full tags list SQL style
		my $dirs = database()->selectcol_arrayref("SELECT `tag` FROM `tags`; "); # push first row into arrayref
		@dirs = @$dirs;
	}else{
		my @regex_dirs;
		my @sql_files;
		my @pathtags = dirpath_to_tags($path);
		for(@pathtags){
			push(@regex_dirs, '^'.$_.'$');
			push(@sql_files, "`tags` REGEXP '$_'");
		}

		my $regex_dirs = join('|',@regex_dirs);
		$regex_dirs = qr/$regex_dirs/;
		my $sql_files = join(" AND ",@sql_files);
		print "## virt_readdir: $path: regex_dirs:$regex_dirs ; sql_files:$sql_files\n" if $self->{debug};

		## gather files: SQL style: results-set
		my %tags;
		$entries = database()->prepare("SELECT `basename`,`tags` FROM `file_tags` WHERE $sql_files; "); # push first row into arrayref
		$entries->execute();
		while( my $entry = $entries->fetchrow_hashref ){
			push(@files, $entry->{basename});

			for( split(/,\s*/,$entry->{tags}) ){
				my $tag_cleaned = lc($_);
				$tag_cleaned =~ s/[^\p{L}\p{N}]//g;	# matches all (Unicode) characters that are neither letters nor numbers
				next if $tag_cleaned =~ $regex_dirs;
				$tags{$_}++;
			}
		}
		@dirs = keys %tags;
	}

	print "## virt_readdir: $path: sub-tags left (as dirs):@dirs ; files:@files\n" if $self->{debug};
	return (@dirs || @files) ? ((@dirs,@files), 0) : 0;
}

sub real_getattr {
	my $file = shift; # we have real paths in the db anyway
	print "real_getattr: file:$file\n" if $self->{debug};
	my (@list) = lstat($file);
	return -ENOENT() unless @list;	# "-ENOENT" was "-$!", but if we compare both in Dumper, "-$!" is a string, and ENOENT is numeric
	return @list;
}

sub virt_getattr {
	my ($path) = shift;
	print "## virt_getattr: path:$path => " if $self->{debug};

	return -ENOENT() unless $self->{tags_cnt};

#	my $cnt = () = $path =~ /\//g; # from an older approach, to find out how deep we are in the tag-path

	## find which file exactly is meant here
	my $file = file_by_tagpath($path);

	if($file){
		return real_getattr( $file );
	}else{
		print "## virt_getattr: path:$path ; file_by_tagpath() returned <undef>\n" if $self->{debug};
		my ($modes) = (0040<<9) + 0775;
		my ($dev, $ino, $rdev, $blocks, $uid, $gid, $nlink, $blksize) = (0,0,0,1,$self->{uid},$self->{gid},1,1024);
		my $size = 0;
		$blocks = $size;
		my ($atime, $ctime, $mtime);
		$atime = $ctime = $mtime = $self->{db_epoch};

		return ($dev,$ino,$modes,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks);
	}
	return -ENOENT(); # never
}

sub real_open {
	my ($path,$mode) = @_;

	## find which file exactly is meant here
	my $file = file_by_tagpath($path);

	return -ENOSYS() if !$file;
	return -ENOENT() unless -e $file;

	my $fh;
	sysopen($fh,$file,$mode) or return -$!;

	return (0, $fh);
}

sub real_read {
	my ($path,$bufsize,$off,$fh) = @_;

	my $rv = -ENOSYS();

	if(seek($fh,$off,SEEK_SET)) {
		read($fh,$rv,$bufsize);
	}

	return $rv;
}

sub real_release {
	my ($path,$mode,$fh) = @_;

	close($fh) or return -$!;

	return 0;
}

sub virt_statfs { return 255, 1, 1, 1, 1, 2 }

sub umount {
	database()->disconnect();
}


1;

__END__

=head1 NAME

Fuse::TagLayer - A read-only tag-filesystem overlay for hierarchical filesystems

=head1 SYNOPSIS

  use Fuse::TagLayer;
  my $ftl = Fuse::PerlSSH::FS->new(
	realdir		=> '/some/local/path',
	mountpoint	=> '/some/local/mountpoint',
	debug		=> 2,
  );
  $ftl->mount();

The bundled L<taglayer> mounting script uses this module here, I<Fuse::TagLayer>, as
its backend. On mount, it scans a specified dir for tags and mounts them as
the TagLayer filesystem at the mountpoint, by default /path/to/specified-dir/+tags.

  taglayer <real directory> [<tag directory mountpoint>]

=head1 DESCRIPTION

Fuse::TagLayer offers all the tags found in one subdir/volume as a tag-based file-system
at the mountpoint you specify, currently read-only. This is in addition to the real
filesystem which is considered to be 'canonical' - with the tag-file-system being
just another "layer" to access these files (thus the name).

=head2 How it works

Fuse::TagLayer, on mount, scans a specified dir-path and gathers all the tags found in
the files' "user.tags" extended-attribute. These xattr-tags are supplemented
by "tags" derrived from what could be called "directory fragments". That means, a
path like "/Path/to/file" is interpreted as being the tags "Path" and "to" (dropping
the filename as source for tags for now). All these tags then are inserted into a
database (SQLite) and the db is used to expose a tag-based file system at the mountpoint.

=head1 METHODS

Right now, the module offers some OO-ish methods, and some plain functions. The mounting
script uses the below OO methods new(), mount() and umount(). But note the quirk that
$self is stored in a global I<our> variable, to mediate between the OO API and the 
Fuse-style functions.

=head2 new()

=head2 mount()

=head2 umount()

=head1 FUNCTIONS

A growing list of functions that match the FUSE bindings, some prefixed by "virt_"
and some by "real_". The latter faciliating the loopback/ pass-trough to the real
filesystem:

  virt_readdir()
  virt_getattr()
  real_getattr()
  real_open()
  real_read()
  real_release()

=head1 EXPORT

None by default.

=head1 CAVEATS or TODO

=head2 Should root contain all or no files?

When we regard the root dir as displaying files without any tags, then only these should show
up. When we regard tags as filters, root would show all files, as on root-level, no
tags (filters) are applied, a bit like in a global key-value filesystem. But when we
think of webapps, most apps will ask you for at least one tag before you can browse
results, so following this paradigm, root should show no files.

=head2 Uniqueness

Currently, filenames, just as tags, are treated as being unique within the tag-filesystem.
So, files of the I<same name> in I<different> directories are not handled properly.
Only one of these name-doublettes might show up after the internal deduplication.

=head2 No tests

No working tests. But everything is read-only so trying TagLayer should be safe.

=head2 On "tagging" (or why it's read-only)

Right now, the resulting tag-fs is read-only, as we haven't implemented write() to the
tag-based path so far. Eventually, when TagLayer grows into a real loop layer, this might
change. Also, once this happens, we have to decide if tags coming from the 'canonical path'
directory elements parsing, are to be considered read-only or not. (Would adding/removing
a tag result in a I<mv> within the underlying real file-system?)

=head2 Tagged directories

Via xattr, it is possible to tag a directory. This is ignored for now, as we regard all 
dirs within the tag-path to be "virtual" and only files in there as being "real". Makes
things easier and is probably in-line with the idea behind a tag-based fs, putting away
with directories.

=head1 SEE ALSO

L<FUSE|Fuse>, obviously.

=head1 AUTHOR

Clipland GmbH L<http://www.clipland.com/>

=head1 COPYRIGHT & LICENSE

Copyright 2012-2013 Clipland GmbH. All rights reserved.

This library is free software, dual-licensed under L<GPLv3|http://www.gnu.org/licenses/gpl>/L<AL2|http://opensource.org/licenses/Artistic-2.0>.
You can redistribute it and/or modify it under the same terms as Perl itself.

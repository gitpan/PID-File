use strict;
use warnings;

use Test::More;
use Test::Exception;

use PID::File;
use PID::File::Guard;

my $pid_file = PID::File->new;

{
	my $guard = PID::File::Guard->new( $pid_file, 'remove' );

	ok( $pid_file->create, "created pid file ok");
		
	ok( -e $pid_file->file, "pid file ('" . $pid_file->file . "') does exist");
}

ok( ! -e $pid_file->file, "guard went out of scope and pid file ('" . $pid_file->file . "') does not exist");

done_testing();

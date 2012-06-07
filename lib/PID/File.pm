package PID::File;

use 5.006;

use strict;
use warnings;

use Fcntl qw(:DEFAULT :flock);
use File::Basename qw(fileparse);
use FindBin qw($Bin);
use Scalar::Util qw(weaken);

use PID::File::Guard;

use constant DEFAULT_SLEEP   => 1;
use constant DEFAULT_RETRIES => 0;

=head1 NAME

PID::File - PID files that guard against exceptions.

=head1 VERSION

Version 0.26

=cut

our $VERSION = '0.26';
$VERSION = eval $VERSION;

=head1 SYNOPSIS

Create PID files.

 use PID::File;
 
 my $pid_file = PID::File->new;
 
 exit if $pid_file->running;

 if ( $pid_file->create )
 {
     # do something
      
     $pid_file->remove;
 }

Or perhaps a bit more robust...

 while ( $pid_file->running || ! $pid_file->create )
 {
     print "Already running, sleeping for 2\n";
     sleep 2;
 }

 $pid_file->guard;
 
 # if we get an exception at this point, $pid_file->remove() will be called automatically
 
 $pid_file->remove;

Using the built-in retry mechanism...

 if ( ! $pid_file->create( retries => 10, sleep => 5 ) )
 {
     die "Could not create pid file after 10 attempts";
 }

 # do something
 
 $pid_file->remove;

=head1 DESCRIPTION

Creating a pid file, or lock file, should be such a simple process.

See L<Daemon::Control> for a more complete solution for creating daemons (and pid files).

The code for this module was largely borrowed from there.

=head1 Methods

=head2 Class Methods

=head3 new

 my $pid_file = PID::File->new;

=cut

sub new
{
	my ( $class, %args ) = @_;
	
	my $self = { file      => $args{ file },
	             guard     => sub { return },
	           };
	
	bless( $self, $class );
	
	return $self;
}

=head2 Instance Methods

=head3 file

The filename for the pid file.

 $pid_file->file( '/tmp/myapp.pid' );

If you specify a relative path, it will be relative to where your scripts runs.

By default it will use the script name and append C<.pid> to it.

=cut

sub file
{
	my ( $self, $arg ) = @_;
	
	$self->{ file } = $arg if $arg;

	if ( ! defined $self->{ file } )
	{
		my @filename = fileparse( $0 );
		$self->{ file } = $Bin . '/';
		$self->{ file } .= shift @filename;
		$self->{ file } .= '.pid';
	}
	
	# relative paths are made absolute, but to the scripts dir
	
	if ( $self->{ file } !~ m:^/: )
	{
		$self->{ file } = $Bin . '/' . $self->{ file };
	}
	
	return $self->{ file };
}

=head3 create

Attempt to create a new pid file.

 if ( $pid_file->create )

Returns true or false for whether the pid file was created.

If the file already exists, and the pid in that file is still running, no action will be taken and it will return false.

If you supply the C<retries> parameter, it will retry that many times, sleeping for C<sleep> seconds (1 by default).

 if ( ! $pid_file->create( retries => 5, sleep => 2 ) )
 {
     die "Could not create pid file";
 }

=cut

sub create
{
	my ( $self, %args ) = @_;
	
	my $sleep   = $args{ sleep }   || DEFAULT_SLEEP;
	my $retries = $args{ retries } || DEFAULT_RETRIES;
		
	my $attempts = 0;
	
	while (	! $self->_create )
	{
		$attempts ++;
		
		return 0 if $attempts > $retries;
		
		sleep $sleep;
	}

	return 1;
}

sub _create
{
	my $self = shift;

	return 0 if $self->running;

	my $fh;
	
	sysopen( $fh, $self->file, O_WRONLY | O_CREAT | O_TRUNC ) or return 0;

	if ( ! flock( $fh, LOCK_EX | LOCK_NB ) )
	{
		# unable to get lock, safer to assume it's running
		close $fh;
		return 0;
	}
	
	print $fh $$ or return 0;
	close $fh    or return 0;

	$self->pid( $$ );
	
	return 1;
}

=head3 pid

 $pid_file->pid

Returns the pid in the pid file, if it exists.

=cut

sub pid
{
	my $self = shift;
	
	$self->{ pid } = $_[0] if @_;
	
	return $self->{ pid };
}

=head3 running

 if ( $pid_file->running )

Returns true or false to indicate whether the pid in the current pid file is running.

=cut

sub running
{
	my $self = shift;

	my $fh;
	
	if ( ! sysopen( $fh, $self->file, O_RDWR ) )
	{
		$self->{ pid } = undef;
		return 0;
	}

	if ( ! flock( $fh, LOCK_EX | LOCK_NB ) )
	{
		# file is locked, safer to assume it's running
		close $fh;
		return 1;
	}
	
	my $pid = do { local $/; <$fh> };
	$self->pid( $pid ) if $pid =~ /^\d+$/;
	close $fh;

	return 0 if ! $self->pid;

	return kill 0, $self->pid;
}

=head3 remove

Removes the pid file.

 $pid_file->remove;

You can only remove a pid file that was created by the current instance of this object.

This is enforced by an internal object mechanism, and not the actual pid in the file.
 
To force the removal of the pid file, supply C<< force => 1 >> in the parameters...

 $pid_file->remove( force => 1 ); 

=cut

sub remove
{
	my ( $self, %args ) = @_;
	
	if ( ! $args{ force } )
	{
		die "Unable to remove file for non-running process" if ! $self->running;
		
		die "Cannot remove pid file that wasn't created by this process" if $self->pid && $self->pid != $$;
	}
		
	unlink $self->file;
	
	$self->{ pid } = undef;
	
	$self->{ guard } = sub { return };

	return $self;
}

=head3 guard

This deals with scenarios where your script may throw an exception before you can remove the lock file yourself.

When called in void context, this configures the C<$pid_file> object to call C<remove> automatically when it goes out of scope.

 if ( $pid_file->create )
 {
     $pid_file->guard;
 
     die;
 }

When called in either scalar or list context, it will return a token.  When that B<token> goes out of scope, C<remove> is called automatically.

This can give you more control on when to automatically remove the pid file.

 if ( $pid_file->create )
 {
     my $guard = $pid_file->guard;
 }
 
 # remove() called automatically, even though $pid_file is still in scope

Note, that if you call C<remove> yourself, the guard configuration will be reset, to save trying to remove the
file again when the C<$pid_file> object finally goes out of scope naturally.

You can only guard a pid file that was created by the current instance of this object.  This is enforced by an internal object mechanism, and not the actual pid in the file.
 
To force the guarding of the pid file, supply C<< force => 1 >> in the parameters

 $pid_file->guard( force => 1 ); 

=cut

sub guard
{
	my ( $self, %args ) = shift;

	if ( ! $args{ force } )
	{
		die "No running process to guard against" if ! $self->running;

		die "Unable to guard file not owned by this process" if $self->pid && $self->pid != $$;
	}
		
	if ( ! defined wantarray )
	{
		weaken $self;   # prevent circular reference

		$self->{ guard } = sub { $self->remove };
		
		return $self;
	}
	else
	{	
		return PID::File::Guard->new( sub { $self->remove; } );
	}
}

sub DESTROY
{
	my $self = shift;
	
	$self->{ guard }->();
}

=head1 AUTHOR

Rob Brown, C<< <rob at intelcompute.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-pid-file at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=PID-File>.  I will be notified, and then you will
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc PID::File

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=PID-File>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/PID-File>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/PID-File>

=item * Search CPAN

L<http://search.cpan.org/dist/PID-File/>

=back

=head1 SEE ALSO

L<Daemon::Control>

L<Scope::Guard>

=head1 LICENSE AND COPYRIGHT

Copyright 2012 Rob Brown.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

1; # End of PID::File


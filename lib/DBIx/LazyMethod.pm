package DBIx::LazyMethod;

#DBIx::LazyMethod for the lazy hest $Id: LazyMethod.pm,v 1.3 2004/03/27 13:45:58 cwg Exp $
#Lazy DBI encapsulation for simple DB handling

use 5.005;
use strict;
use Carp;
use DBI;
use Exporter;
use vars qw($VERSION $AUTOLOAD @EXPORT @ISA %RETSIGN2CODE);

use constant RETURN_VALUES => qw(WANT_ARRAY WANT_ARRAYREF WANT_HASHREF WANT_ARRAY_HASHREF WANT_RETURN_VALUE WANT_ARRAY_ARRAYREF WANT_RETVAL WANT_AUTO_INCREMENT WANT_HANDLE); #The return value names
@EXPORT 	= RETURN_VALUES; 
@ISA    	= qw(Exporter);
$VERSION 	= do { my @r=(q$Revision: 1.3 $=~/\d+/g); sprintf "%d."."%02d"x$#r,@r };
my $PACKAGE 	= "[DBIx::LazyMethod]";

#Public exported constants
use constant WANT_ARRAY 		=> 1;
use constant WANT_ARRAYREF 		=> 2;
use constant WANT_HASHREF 		=> 3;
use constant WANT_ARRAY_HASHREF 	=> 4;
use constant WANT_RETURN_VALUE 		=> 5; 
use constant WANT_RETVAL         	=> 5; #deprecated in favor of WANT_RETURN_VALUE, maintained for compat
use constant WANT_AUTO_INCREMENT 	=> 6;
use constant WANT_HANDLE         	=> 7;
use constant WANT_ARRAY_ARRAYREF 	=> 8;
use constant WANT_METHODS 		=> (WANT_ARRAY,WANT_ARRAYREF,WANT_ARRAY_ARRAYREF,WANT_HASHREF,WANT_ARRAY_HASHREF,WANT_RETURN_VALUE,WANT_AUTO_INCREMENT,WANT_HANDLE); #The return values

#Private constants
use constant TRUE 			=> 1;
use constant FALSE 			=> 0;
use constant PRIVATE_METHODS 		=> qw(new AUTOLOAD DESTROY _connect _disconnect _error);

#debug constant
use constant DEBUG 			=> 0;

#JENDAs improved retval syntax
%RETSIGN2CODE = (
	'@'	=> WANT_ARRAY,
	'\@'	=> WANT_ARRAYREF,
	'\%'	=> WANT_HASHREF,
	'%'	=> WANT_HASHREF,
	'@%'	=> WANT_ARRAY_HASHREF,
	'@@'	=> WANT_ARRAY_ARRAYREF,
	'$'	=> WANT_RETURN_VALUE,
	'$++'	=> WANT_AUTO_INCREMENT,
	'<>'	=> WANT_HANDLE
);


#methods
sub new {
	my $class = shift;
	my %args = @_;
	my $self = bless {}, ref $class || $class;

	#did we get methods?
	my $methods_ref = $args{'methods'};
	unless (ref $methods_ref eq 'HASH') {
		die "$PACKAGE invalid methods definition: argument methods must be hashref";
	}
	#anything in it?
	unless (keys %$methods_ref > 0) {
		die "$PACKAGE no methods in methods hash";
	}
	#lets check the stuff
	my ($dbd_name) = $args{'data_source'} =~ /^dbi:(.*?):/i; 
	#this approach will have to change when we start to accept an already create DBI handle
	my $good_methods = 0;
	foreach my $methname (keys %$methods_ref) {
		#check for internal names / reserwed words in method names
		if (grep { $methname eq $_ } PRIVATE_METHODS) {
			die "$PACKAGE method name $methname is a reserved method name";
		}
		unless (exists $methods_ref->{$methname}->{sql} && defined $methods_ref->{$methname}->{sql}) {
			die "$PACKAGE method $methname: missing sql definition";
		}
		unless (exists $methods_ref->{$methname}->{args} && defined $methods_ref->{$methname}->{args}) {
			die "$PACKAGE method $methname: missing argument definition";
		}
		unless (exists $methods_ref->{$methname}->{ret} && defined $methods_ref->{$methname}->{ret}) {
			die "$PACKAGE method $methname: missing return data definition";
		}

		#translate JENDAs symbols to the WANT_METHODS
		if ( $methods_ref->{$methname}->{ret} !~ /^\d+$/ ) {    # the ret specification is a sign, not an id
			$methods_ref->{$methname}->{ret} = $RETSIGN2CODE{ $methods_ref->{$methname}->{ret} };
		}

		#a way to validate SQL could be nice.
		unless ($methods_ref->{$methname}->{sql}) {
			die "$PACKAGE method $methname: sql definition is empty";
		}
		unless (ref $methods_ref->{$methname}->{args} eq 'ARRAY') {
			die "$PACKAGE method $methname: bad argument list";
		}
		unless (grep { $methods_ref->{$methname}->{ret} eq $_ } WANT_METHODS ) {
			die "$PACKAGE bad return value definition in method $methname";
		}

		#check if we got the right amout of args - Cleanup on aisle 9!
		my $arg_count = @{$methods_ref->{$methname}->{args}};
		#we should probably rather get amount of placeholders from DBI at some point. But then we can't do it before a prepare.
		my @placeholders = $methods_ref->{$methname}->{sql} =~ m/\?/g;

		unless ($arg_count == scalar @placeholders) {
			warn "$PACKAGE method $methname: argument list does not match number of placeholders in SQL. You should get an error from DBI.";
		}

		#check DBD specific issues
		if ($methods_ref->{$methname}->{ret} == WANT_AUTO_INCREMENT) {
			unless (grep { lc $dbd_name eq $_ } qw(mysql pg)) {
				die "$PACKAGE return value type WANT_AUTO_INCREMENT not supported by $dbd_name DBD in method $methname";
			}
		}

		# Since 'noprepare' causes us to do a $dbh->do, we cannot return anything else than WANT_RETURN_VALUE	
		if ($methods_ref->{$methname}->{ret} != WANT_RETURN_VALUE && exists $methods_ref->{$methname}->{'noprepare'}) {
			die "$PACKAGE return value for $methname must be WANT_RETURN_VALUE if 'noprepare' option is used";
		}

		# Use of 'noquote' option is depending on 'noprepare' option. Check that it is set.
		if (exists $methods_ref->{$methname}->{'noquote'} && !exists $methods_ref->{$methname}->{'noprepare'}) {
			warn "$PACKAGE useless use of 'noquote' option without required 'noprepare' option for method $methname";
		}

		$good_methods++;
	}
	unless ($good_methods > 0) {
		die "$PACKAGE no usable methods in methods hashref";
	}

	#TODO: more input checking?
	#At some point an existing $dbh object could be passed as an argument to new() instead of this.
	$self->{'methods'} 		= $methods_ref;		
	$self->{'_data_source'} 	= $args{'data_source'} 		|| die "Argument data_source missing";
	$self->{'_user'} 		= $args{'user'} 		|| "";
	$self->{'_pass'}  		= $args{'pass'} 		|| undef; 
	$self->{'_attr'} 		= $args{'attr'} 		|| undef;

	#How to deal with errors
	$self->{'_on_errors'}		= $args{'on_errors'}	  	|| 'carp';
	if (exists $args{'format_errors'} and ref( $args{'format_errors'} ) eq 'CODE') {
		$self->{'_format_errors'} = $args{'format_errors'}
	}

	#if default values have been provided	
	if (exists $args{'defaults'}) {
		$self->{'defaults'} 	= $args{'defaults'};
	}
	#JENDA naming
	if (exists $args{'session'}) {
		$self->{'defaults'} 	= $args{'session'};
	}

	$self->{'warn_useless'} = ( exists $args{'warn_useless'} ? $args{'warn_useless'} : 1 );

	#connect us
	$self->{'_dbh'} 		= $self->_connect;
	
	return $self;
}

sub AUTOLOAD {
	my $self = shift;
	my %args = @_;
	my ($methname) = $AUTOLOAD =~ /.*::([\w_]+)/;

	#clear the error register
	delete $self->{'errorstate'};
	$self->{'errormessage'} = "[unknown]";

	#is it a method
	if (exists $self->{'methods'}{$methname}) {
		my $meth = $self->{'methods'}{$methname};

		#figure out how to deal with errors for this method
		$self->{'_on_error'} = delete $args{'_error'} || delete $args{'_on_error'} || $meth->{'en_errors'}; # move the '_error' message from args to the object

		#we need a DBI handle
		unless (exists $self->{_dbh} && ref $self->{_dbh} eq 'DBI::db') {
			return $self->_error("DBI handle missing");
		}
		if (!$self->{_dbh}->{'Active'}) {	# the connection is broken
            		delete $self->{'statements'};	# need to forget we ever prepared anything
            		$self->_connect();
        	}

		#create the statement if it does not already exist
		if (!exists $self->{'statements'}{$methname}) {
			#prepare the new DBI statement handle - unless it's a no-prepare type
			if (defined $meth->{'noprepare'}) {
				$self->{'statements'}{$methname} = TRUE;    #faking it
			} else {
				$self->_prepare($methname) or return $self->_error($methname." prepare failed");
			}
		}
		my $sth = $self->{'statements'}{$methname};
		
		#put the required bind values here
		my @bind_values = ();
		my $cnt = 0;

		#run through the args defined for the method
		foreach (@{$meth->{'args'}}) {
			$cnt++;
			if (exists $args{$_}) {
				push @bind_values, $args{$_};
			} 
			elsif (exists $self->{defaults} and exists $self->{defaults}{$_}) {
				push @bind_values, $self->{defaults}{$_};
			}
			else { 
				return $self->_error($methname." Insufficient parameters (".$_.")");
			}

			#for checking argument count later
			delete $args{$_};

			#puha hack for placeholders til MySQL limit syntax
			#TODO: investigate how this can be done in Pg
			next unless ($self->{_dbh}->{Driver}->{Name} eq 'mysql');

			# If we haven't prepared the $sth, then don't call it
			next unless (exists $meth->{'noprepare'});

			if ($_ =~ /^limit_/) { $sth->bind_param($cnt,'',DBI::SQL_INTEGER); }
		}

		#warn if more arguments than needed was provided
		if ( $self->{'warn_useless'} or DEBUG ) {
			foreach (keys %args) {
				carp "$PACKAGE WARN: useless argument \"".$_."\" provided for method \"".$methname."\"";
			}
		}

		#do it
		my $rv;	
		if  (exists $meth->{'noprepare'}) {
			# Execute the SQL directly - as we have no prepared $sth
			my $sql = $meth->{sql};
			if (exists $meth->{'noquote'}) {
				# HACK: danger will robinson. danger.
				my $sql = $meth->{sql};
				$sql =~ s/\?+?/(shift @bind_values)/oe while (@bind_values);
				$rv = $self->{_dbh}->do($sql) or return $self->_error("_sth_".$methname." do failed : ".DBI::errstr);
			} else {
				# Let's quote the bind_values
				#$sql =~ s/\?+?/($self->{_dbh}->quote_identifier(shift @bind_values))/oe while (@bind_values);
				$rv = $self->{_dbh}->do($meth->{sql},undef,@bind_values) or return $self->_error("_sth_".$methname." do failed : ".DBI::errstr);
			}
		} else {
			# Execute the query normally on the statement handle
			$rv = $sth->execute(@bind_values);
		}
		print STDERR "$PACKAGE DEBUG:  DBI: ".DBI::errstr."\n" if (!$rv && DEBUG);
		unless ($rv) { $self->_error("DBI execute error: ".DBI::errstr); $sth->finish; return }

		my ($ret) = $meth->{ret};
		print STDERR "Found ret for $methname: $ret\n" if DEBUG;

		if ($meth->{ret} == WANT_ARRAY) {
			my @ret;
			while (my (@ref) = $sth->fetchrow_array) { push @ret,@ref }
			return @ret;
		} elsif ($meth->{ret} == WANT_ARRAYREF) {
			my $ret = $sth->fetchrow_arrayref;
			if ((!defined $ret) || (ref $ret eq 'ARRAY')) {
				return $ret;
			} else {
				return $self->_error("_sth_".$methname." is doing fetching on a non-SELECT statement");
			}
		} elsif ($meth->{ret} == WANT_HASHREF) {
			my $ret = $sth->fetchrow_hashref;
			if ((!defined $ret) || (ref $ret eq 'HASH')) {
				return $ret;
			} else {
				return $self->_error("_sth_".$methname." is doing fetching on a non-SELECT statement");
			}
		} elsif ($meth->{ret} == WANT_ARRAY_ARRAYREF) {
			my @ret;
			while (my $ref = $sth->fetchrow_arrayref) {
				push @ret, $ref;
			}
			return \@ret;
		} elsif ($meth->{ret} == WANT_ARRAY_HASHREF) {
			my @ret;
			while (my $ref = $sth->fetchrow_hashref) {
				push @ret, $ref;
			}
			return \@ret;
		} elsif ($meth->{ret} == WANT_AUTO_INCREMENT) {

			my $cur_dbd = $self->{_dbh}->{Driver}->{Name};
			unless ($cur_dbd) { return $self->_error("Unknown DBD '".$cur_dbd."'"); }

			# TODO: check DBD version to make sure it supports the index/auto_increment stuff

			if (lc $cur_dbd eq 'mysql') {
				#MySQL index/auto_increment hack
				if (exists $sth->{'mysql_insertid'}) { 
					return $sth->{'mysql_insertid'};
				} else {
					return $self->_error("_sth_".$methname." could not get mysql_insertid from mysql DBD");
				}
			}
			elsif (lc $cur_dbd eq 'pg') {
				#PostgreSQL index/auto_increment hack
				if (exists $sth->{'pg_oid_status'}) { 
					return $sth->{'pg_oid_status'};
				} else {
					return $self->_error("_sth_".$methname." could not get pg_oid_status from Pg DBD");
				}
			} else {
				return $self->_error("_sth_".$methname." is using DBD specific AUTO_INCREMENT on unsupported DBD");
			}
		} elsif ($meth->{ret} == WANT_RETURN_VALUE) {
			return $rv;
		} elsif ($meth->{ret} == WANT_HANDLE ) {
			return $sth;
		} else {
			return $self->_error("No such return type for ".$methname);
		}

        } else {
                return $self->_error("No such method: $AUTOLOAD");
        }
}

sub DESTROY ($) {
	my $self = shift;
	#do we have any methods?
	if (exists $self->{'methods'}) {
		#remember to bury statement handles
		foreach (keys %{$self->{'methods'}}) {
			#ignore if we haven't used a sth
			next if (exists $self->{'methods'}{$_}->{'noprepare'});
			#if the sth of a methods is defined it has been used
        	        if (exists $self->{'_sth_'.$_}) {
				#finish the sth
                	        $self->{'_sth_'.$_}->finish;
               		        print STDERR "$PACKAGE DEBUG: method DESTROY - finished _sth_".$_." handle\n" if DEBUG;
               	 	}
		}
	}
	#and hang up if we have a connection
        if (exists $self->{'_dbh'}) { $self->_disconnect(); }
}

sub _connect {
        my $self = shift;

	my $data_source =	$self->{'_data_source'};
        my $user 	= 	$self->{'_user'};
        my $auth  	= 	$self->{'_pass'};
        my $attr  	= 	$self->{'_attr'};

	#$dbh = DBI->connect($data_source, $username, $auth, \%attr);

	#TODO: validate args
	if (defined $attr) {
		unless ((ref $attr) eq 'HASH') { die "argument 'attr' must be hashref"; }
	}

	print STDERR "$PACKAGE DEBUG: DBIx::LazyMethod doing: DBI->connect($data_source, $user, $auth, $attr);\n" if DEBUG;
	my $dbh  = DBI->connect($data_source, $user, $auth, $attr) or return $self->_error("Connection failure [".DBI::errstr."]");
	return $dbh;
}

sub _disconnect {
        my $self = shift;
        my $dbh = $self->{'_dbh'};

        unless (defined $dbh) { return TRUE }

        if (!$dbh->disconnect) {
                $self->_error("Disconnect failed [".DBI::errstr."]");
        } else {
		print STDERR "$PACKAGE DEBUG: Disconnected dbh\n" if DEBUG;
        }
	return TRUE;
}

sub _prepare {
	my ($self,$methname) = @_;
	my $meth = $self->{'methods'}{$methname};
	print STDERR "$PACKAGE DEBUG: preparing ".$meth->{sql}."\n" if DEBUG;
	$self->{'statements'}{$methname} = $self->{_dbh}->prepare($meth->{sql}) or return $self->_error( $meth . " prepare failed" );
}

sub _error {
        my ($self,$data) = (shift,shift);

	my $on_error = $self->{'_on_error'} || $self->{'_on_errors'};    # method specific or global
    
        $data = $self->{'_format_errors'}->($data) if exists $self->{'_format_errors'};
        return unless $data;

        $self->{'errorstate'} = TRUE;
        $self->{'errormessage'} = $data;

	if (ref($on_error eq 'CODE')) {
		return $on_error->($data);
	} elsif ($on_error eq 'die') {
		die $data;
	} elsif ($on_error eq 'croak') {
		croak $data;
	} elsif ($on_error =~ /\b_ERROR_\b/) {
		$on_error =~ s/\b_ERROR_\b/$data/g;
		if (ref($self->{'_on_errors'}) eq 'CODE') {
			return $self->{'_on_errors'}->($on_error);
		} elsif ($on_error =~ /\n$/) {
			die $on_error;
		} else {
			carp $on_error;
		}
	} else {
		carp "$PACKAGE ERROR: " . $data;
	}
        return;
}

sub is_error ($) {
	my $self = shift;
	return (exists $self->{'errorstate'})?TRUE:FALSE;
}

1;

__END__

=head1 NAME

DBIx::LazyMethod - Simple 'database query-to-accessor method' wrappers. 

=head1 SYNOPSIS

When used directly:

  use DBIx::LazyMethod;

  my %methods = (
	set_people_name_by_id => {
		sql => "UPDATE people SET name = ? WHERE id = ?",
		args => [ qw(name id) ],
		ret => WANT_RETURN_VALUE,
	},
	get_people_entry_by_id => {
		sql => "SELECT * FROM people WHERE id = ?",
		args => [ qw(id) ],
		ret => WANT_HASHREF,
	},
	# Although not really recommended, you can also change the database schema
	drop_table => {
		sql => "DROP TABLE ?",
		args => [ qw(table) ],
		ret => WANT_RETURN_VALUE,
		noprepare => 1, # For non-prepareable queries
		noquote => 1, 	# For non-quoteable arguments (like table names)
	},
  );

  #set up the above methods on a Oracle database accessible through a DBI proxy 
  my $db = DBIx::LazyMethod->new(
		data_source  => "DBI:Proxy:hostname=192.168.1.1;port=7015;dsn=DBI:Oracle:PERSONS",
                user => 'user',
                pass => 'pass',
                attr => { 'RaiseError' => 0, 'AutoCommit' => 1 },
                methods => \%methods,  
                );
  if ($db->is_error) { die $db->{errormessage}; }

 Accessor methods are now available:
 
  $db->set_people_name_by_id(name=>'Arne Raket', id=>42);
  if ($db->is_error) { die $db->{errormessage}; }

  $db->drop_table(table=>'pony');
  if ($db->is_error) { die $db->{errormessage}; }

When sub-classed:

  use MyDB;	# Class inheriting everything from DBIx::LazyMethod except for 
		# the C<new> method - which is just a call to DBIx::LazyMethod 
		# with appropriate arguments - returning a DBIx::LazyMethods 
		# object. See lib/SomeDB.pm for an example.

  my $db = MyDB->new() or die;
 
 Accessor methods are now available:

  my $entry_ref = $db->get_people_entry_by_id(id=>42);

=head1 DESCRIPTION

A Lazy (and easily replaceable) DB abstraction layer.
In no way a new approach, rather an easy one. You should probably use DBIx::Class anyway. Heh.

=head2 What does that mean?

DBIx::LazyMethod uses AUTOLOAD to create methods and statement handles based on the 
data in the hashref supplied in the argument 'methods'.
Statement handles are persistent in the lifetime of the instance.
It is an easy way to set up accessor methods for a fixed (in the sense of
database and table layout) data set.

When the DBIx::LazyMethod object is created, it is verified, for each method in the 
'methods' hashref, that the amount of required arguments
matches the amount of placeholders in the SQL (C<"?">). 

When a method defined in the 'methods' hashref is invoked, it is verified that the arguments
in 'args' are provided. The arguments are then applied to the persistent
statement handle (eg. _sth_set_people_name_by_id) that is created from the value 'sql' 
statement.

If the 'args' start with 'limit_' they are handled specially to enable placeholders
for 'LIMIT X,Y' (MySQL) syntax - if mysql DBD is used.

=head2 Why did you do that?

I was annoyed by the fact that I had to create virtually similar DB packages time and time again.
DBIx::LazyMethod started out as an experiment in how generic a (simple) DB module could be made. 
In many situations you would probably want to create a specialized DB package - but this one should get you started, without you having to change your interfaces at a later point.
Besides that. I'm just lazy.

=head1 KEYS IN METHODS DEFINITION

The 'args', 'sql' and 'ret' are mandatory arguments to each defined method.

The 'noprepare' and 'noquote' arguments are optional.

=head2 args 

The value of 'args' is an array of key names. The keys must be in the same order as the mathing SQL placeholders ("?").
When the object is created, it is checked that the amount of keys match the amount of SQL placeholders.

=head2 sql

The 'sql' key holds the string value of the fixed SQL syntax. 

=head2 ret 

The value of 'ret' (return value) can be:

=over 4

=item *
	WANT_ARRAY / '@' - returns an array (or array ref in scalar context) containing all the rows concatenated together.
	This is especially handy for queries returning just one column. (SELECT)

=item *
	WANT_ARRAYREF / '\@' - returns a reference to an array containing the data of the first row.
	Other rows are not returned! (SELECT)

=item *
	WANT_HASHREF / '\%' - returns a reference to a hash containing the data of the first row.
	Other rows are not returned! (SELECT)

=item *
	WANT_ARRAY_HASHREF / '@%' - returns an array of hashrefs (SELECT)

=item *
	WANT_ARRAY_ARRAYREF / '@@' - returns an array of arrayrefs (SELECT)

=item *
	WANT_RETURN_VALUE / '$' - returns the DBI return value (NON-SELECT)

=item *
	WANT_AUTO_INCREMENT / '$++' - returns the new auto_increment value of an INSERT (MySQL/Pg specific. SELECT @@IDENTITY variable for MS SQL).

=item *
	WANT_HANDLE / '<>' - returns the DBI statement handle. You may call the fetchxxx_xxx() methods you need then (SELECT)

=back

=head2 noprepare 

The existence of the 'noprepare' key indicates that the method should not use a prepared statement handle for execution.
This is really just slower. It should be used when executing queries that cannot be prepared. (Like 'DROP TABLE ?').
It only works with non-SELECT statements. So setting 'ret' to anything else than WANT_RETURN_VALUE will cause an error.
See the 'bind_param' section of the 'Statement Handle Methods' in the DBI documentation for more information.

=head2 noquote

The existence of the 'noquote' key indicates that the arguments listed should not be quoted.
This is for dealing with table names (Like 'DROP TABLE ?'). It's really a hack. 
The 'noquote' key has no effect unless used in collaboration with the 'noprepare' key on a method.

=head2 on_errors

This parameter overrides the global C<on_errors> parameter with one exception. If you specify an error template
and the global C<on_errors> is a subroutine reference then DBIx::LazyMethod first fills in the template and then calls that subroutine.
See the ERROR HANDLING section for details.

=cut

=head1 CLASS METHODS

The following methods are available from DBIx::LazyMethod objects. Any
function or method not documented should be considered private.  If
you call it, your code may break someday and it will be B<your> fault.

The methods follow the Perl tradition of returning false values when
an error occurs (and usually setting $@ with a descriptive error
message).

Any method which takes an SQL query string can also be passed bind
values for any placeholders in the query string:

=over 4

=item C<new()>

The C<new()> constructor creates and returns a database connection
object through which all database actions are conducted. On error, it
will call C<die()>, so you may want to C<eval {...}> the call.  The
C<NoAbort> option (described below) controls that behavior.

C<new()> accepts ``hash-style'' key/value pairs as arguments.  The
arguments which it recognizes are:

=over 8

=item C<data_source>

The data source normally fed to DBI->connect. Normally in the format of C<dbi:DriverName:database_name>.

=item C<user>

The database connection username. 

=item C<pass>

The database connection password. 

=item C<attr>

The database connection attributes. Leave blank for DBI defaults.

=item C<methods>

The methods hash reference. Also see the KEYS IN METHODS DEFINITION description.

=item C<defaults> (optional)

A hash reference to default values. This allows you to specify the default values for arguments to your methods.
If you do not specify the value of an argument of a method it is looked up in the defaults hash and only if not found there do you get an error.
You may access the defaults via C< $db-E<gt>{'defaults'} >. This is only usefull if you name your arguments consistently and you do have
some values (say, a session id) that are passed to lots of methods.

=item C<noprepare> (optional)

If defined - causes the method to be executed directly, without involving a statement handle.

=item C<noquote> (optional)

When defined, the arguments will not be quoted/escaped before execution. This is normally only used for table names.
C<noprepare> must also be defined for this option to work.

=item C<format_errors> (optional)

This subroutine gets called for each error and may be used to reformat it. It gets the error message as its first
argument and is supposed to return the reformated message. If it returns undef or an empty string no error is reported
and the method that caused the error returns undef. This is evaluated before the error details are added!

=item C<on_errors> (optional)

This may be either a reference to a procedure to be called to report the errors or one of the strings
'carp', 'croak' or 'die' or an error message template.

If you specify a code reference then DBIx::LazyMethod calls your subroutine passing the error message
(after formatting and with the error details added) as the first argument and returns whatever that subroutine returns.

If you specify 'carp', 'croak' or 'die' them DBIx::LazyMethod calls the respective function with the error message.

If you specify some other string then DBIx::LazyMethod replaces the token _ERROR_ in the string by the actuall
error message and then either die()s (if the error template ends with a newline) or carp()s.

=back

=cut

=item C<is_error()> (deprecated)

Whenever an error occures (and is not forced to be ignored by the format_errors subroutine) the module sets an internal flag in the object
that may be queried by method is_error() and stores the error message in C< $db-E<gt>{errormessage}; >.

=back

=head1 ERROR HANDLING

By default all methods carp() in case there is an error. You can specify that they should die() or croak() instead or that a function you specify should be called.
You may also provide a formatting subroutine that will be called on the error messages before the carp(), croak(), die() or the callback function.
Apart from this you may ask DBIx::LazyMethod to include the call details in the error message. If you do so then the error message will
(if possible) contain a snippet of SQL that is being executed, including the values. This is usualy NOT exactly the thing being executed
against the database though, DBIx::LazyMethod prepares the statements and uses placeholders.

You may then change the way errors are reported when defining the methods or when calling them.

=head2 Constructor parameters

=over 4

=item C<format_errors>

This subroutine gets called for each error and may be used to reformat it. It gets the error message as its first
argument and is supposed to return the reformated message. If it returns undef or an empty string no error is reported
and the method that caused the error returns undef. This is evaluated before the error details are added!

=item C<error_details>

This is a boolean parameter. If set to a true value, DBIx::LazyMethod includes the executed SQL in the error message.

=item C<on_errors>

This may be either a reference to a procedure to be called to report the errors or one of the strings
'carp', 'croak' or 'die' or an error message template.

If you specify a code reference then DBIx::LazyMethod calls your subroutine passing the error message
(after formatting and with the error details added) as the first argument and returns whatever that subroutine returns.

If you specify 'carp', 'croak' or 'die' them DBIx::LazyMethod calls the respective function with the error message.

If you specify some other string then DBIx::LazyMethod replaces the token _ERROR_ in the string by the actuall
error message and then either die()s (if the error template ends with a newline) or carp()s.

=back


=head2 Method definition parameters


=head2 Method call parameters

=over 4

=item C<_error/_on_error>

This parameter overrides the C<on_errors> parameter specified either globaly or in the method definition.
Like above, if you specify an error template and the global C<on_errors> is a code reference then DBIx::LazyMethod first fills in the template
and then calls that subroutine.

=back

Whenever an error occures (and is not forced to be ignored by the format_errors subroutine) the module sets an internal flag in the object
that may be queried by method is_error() and stores the error message in C< $db-E<gt>{errormessage}; >.

=head1 COPYRIGHT

Copyright (c) 2002-09 Casper Warming <warming@cpan.org>.  All rights
reserved.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
Artistic License for more details.

=head1 AUTHORS

Casper Warming <warming@cpan.org>

Jenda Krynicky <Jenda@Krynicky.cz>

=head1 TODO

=over 

=item Better documentation.

=item More "failure" tests.

=item Testing expired statement handles.

=back

=head1 ACKNOWLEDGEMENTS

=over

=item Copenhagen Perl Mongers for the motivation. 

=item Apologies to Thomas Eibner for not naming the module Doven::Hest.

=item JONASBN for reporting errors and helping with Pg issues.

=item JENDA for continued development and feature suggestions.

=back

=head1 SEE ALSO

DBIx::DWIW

DBIx::Class

Class::Accessor

DBI(1).

=cut


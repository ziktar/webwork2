################################################################################
# WeBWorK Online Homework Delivery System
# Copyright � 2000-2006 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/lib/WeBWorK/DB/Schema/NewSQL.pm,v 1.6 2006/09/29 19:37:55 sh002i Exp $
# 
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package WeBWorK::DB::Schema::NewSQL;
use base qw(WeBWorK::DB::Schema);

=head1 NAME

WeBWorK::DB::Schema::NewSQL - support SQL access to all tables.

=cut

use strict;
use warnings;
use Carp qw(croak);
use Iterator;
use Iterator::Util;
use WeBWorK::DB::Utils::SQLAbstractIdentTrans;
use WeBWorK::Debug;

use constant TABLES => qw(*);
use constant STYLE  => "dbi";

{
	no warnings 'redefine';
	
	sub debug {
		my ($self, @string) = @_;
		WeBWorK::Debug::debug(@string) if $self->{params}{debug};
	}
}

=head1 SUPPORTED PARAMS

This schema pays attention to the following items in the C<params> entry.

=over

=item tableOverride

Alternate name for this table, to satisfy SQL naming requirements.

=item fieldOverride

A reference to a hash mapping field names to alternate names, to satisfy SQL
naming requirements.

=back

=cut

# FIXME -- external field lists should contain WW field names, and should get
# translated into SQL field names inside the functions. (right now, we expect
# SQL field names in *_fields_*.)
# 
# this is also a problem in the WHERE clause definitions... is that fixable?

################################################################################
# constructor for SQL-specific behavior
################################################################################

sub new {
	my ($proto, $db, $driver, $table, $record, $params) = @_;
	my $self = $proto->SUPER::new($db, $driver, $table, $record, $params);
	
	# transformation functions for table and field names: these allow us to pass
	# the WeBWorK table/field names to SQL::Abstract, and have it translate them
	# to the SQL table/field names from tableOverride and fieldOverride.
	# (Without this, it would be hard to translate field names in WHERE
	# structures, since they're so convoluted.)
	my ($transform_table, $transform_field);
	if (defined $params->{tableOverride}) {
		$transform_table = sub {
			my $label = shift;
			if ($label eq $self->{table}) {
				return $self->{params}{tableOverride};
			} else {
				warn "can't transform unrecognized table name '$label'";
				return $label;
			}
		};
	}
	if (defined $params->{fieldOverride}) {
		$transform_field = sub {
			my $label = shift;
			return defined $self->{params}{fieldOverride}{$label}
				? $self->{params}{fieldOverride}{$label}
				: $label;
		};
	}
	
	# add SQL statement generation object
	$self->{sql} = new WeBWorK::DB::Utils::SQLAbstractIdentTrans(
		quote_char => "`",
		name_sep => ".",
		transform_table => $transform_table,
		transform_field => $transform_field,
	);
	
	return $self;
}

################################################################################
# table creation
################################################################################

sub create_table {
	my ($self) = @_;
	
	my $stmt = $self->_create_table_stmt;
	return $self->dbh->do($stmt);
}

# this is mostly ripped off from wwdb_check, which is pretty much a per-table
# version of the table creation code in sql_single.pm. wwdb_check is going away
# after 2.3.x, and sql_single.pm is being replaced by this code.
sub _create_table_stmt {
	my ($self) = @_;
	
	my $sql_table_name = $self->sql_table_name;
	my %field_data = $self->field_data;
	
	my @field_list;
	
	# generate a column specification for each field
	foreach my $field ($self->fields) {
		my $sql_field_name = $self->sql_field_name($field);
		my $sql_field_type = $field_data{$field}{type};
		
		push @field_list, "`$sql_field_name` $sql_field_type";
	}
	
	# generate an INDEX specification for each all possible sets of keyfields (i.e. 0+1+2, 1+2, 2)
	my @keyfields = $self->keyfields;
	foreach my $start (0 .. $#keyfields) {
		my @index_components;
		
		foreach my $component (@keyfields[$start .. $#keyfields]) {
			my $sql_field_name = $self->sql_field_name($component);
			my $sql_field_type = $field_data{$component}{type};
			my $length_specifier = $sql_field_type =~ /(text|blob)/i ? "(255)" : "";
			if ($start == 0 and $length_specifier and $sql_field_type !~ /tiny/i) {
				warn "warning: UNIQUE KEY component $sql_field_name is a $sql_field_type, which can"
					. " hold values longer than 255 characters. However, the maximum key prefix"
					. " length for text/blob fields is 255. Therefore, uniqueness must occur within"
					. " the first 255 characters of this field.";
			}
			push @index_components, "`$sql_field_name`$length_specifier";
		}
		
		my $index_string = join(", ", @index_components);
		my $index_type = $start == 0 ? "UNIQUE KEY" : "KEY";
		push @field_list, "$index_type ( $index_string )";
	}
	
	my $field_string = join(", ", @field_list);
	return "CREATE TABLE `$sql_table_name` ( $field_string )";
}

################################################################################
# table renaming
################################################################################

sub rename_table {
	my ($self, $new_sql_table_name) = @_;
	
	my $stmt = $self->_rename_table_stmt($new_sql_table_name);
	return $self->dbh->do($stmt);
}

sub _rename_table_stmt {
	my ($self, $new_sql_table_name) = @_;
	
	my $sql_table_name = $self->sql_table_name;
	return "RENAME TABLE `$sql_table_name` TO `$new_sql_table_name`";
}

################################################################################
# table deletion
################################################################################

sub delete_table {
	my ($self) = @_;
	
	my $stmt = $self->_delete_table_stmt;
	return $self->dbh->do($stmt);
}

sub _delete_table_stmt {
	my ($self) = @_;
	
	my $sql_table_name = $self->sql_table_name;
	return "DROP TABLE `$sql_table_name`";
}

################################################################################
# counting/existence
################################################################################

# returns the number of matching rows
sub count_where {
	my ($self, $where) = @_;
	
	my ($stmt, @bind_vals) = $self->sql->select($self->table, "COUNT(*)", $where);
	my $sth = $self->dbh->prepare_cached($stmt, undef, 3); # 3 -- see DBI docs
	$sth->execute(@bind_vals);
	my ($result) = $sth->fetchrow_array;
	$sth->finish;
	
	return $result;
}

# returns true iff there is at least one matching row
sub exists_where {
	my ($self, $where) = @_;
	return $self->count_where($where) > 0;
}

################################################################################
# lowlevel get
################################################################################

# returns a list of refs to arrays containing field values for each matching row
sub get_fields_where {
	my ($self, $fields, $where, $order) = @_;
	
	my $sth = $self->_get_fields_where_prepex($fields, $where, $order);
	my @results = @{ $sth->fetchall_arrayref };
	$sth->finish;
	return @results;
}

# returns an Iterator that generates refs to arrays containg field values for each matching row
sub get_fields_where_i {
	my ($self, $fields, $where, $order) = @_;
	
	my $sth = $self->_get_fields_where_prepex($fields, $where, $order);
	return new Iterator sub {
		my $row = $sth->fetchrow_arrayref;
		if (defined $row) {
			return [@$row]; # need to make a copy here, since DBI reuses arrayrefs
		} else {
			$sth->finish; # let the server know we're done getting values (is this necessary?)
			undef $sth; # allow the statement handle to get garbage-collected
			Iterator::is_done();
		}
	};
}

# helper, returns a prepared statement handle
sub _get_fields_where_prepex {
	my ($self, $fields, $where, $order) = @_;
	
	my ($stmt, @bind_vals) = $self->sql->select($self->table, $fields, $where, $order);
	my $sth = $self->dbh->prepare_cached($stmt, undef, 3); # 3: see DBI docs
	$sth->execute(@bind_vals);	
	return $sth;
}

################################################################################
# getting keyfields (a.k.a. listing)
################################################################################

# returns a list of refs to arrays containing keyfield values for each matching row
sub list_where {
	my ($self, $where, $order) = @_;
	return $self->get_fields_where([$self->keyfields], $where, $order);
}

# returns an iterator that generates refs to arrays containing keyfield values for each matching row
sub list_where_i {
	my ($self, $where, $order) = @_;
	return $self->get_fields_where_i([$self->keyfields], $where, $order);
}

################################################################################
# getting records
################################################################################

# returns a record objects for each matching row
sub get_records_where {
	my ($self, $where, $order) = @_;
	
	return map { $self->box($_) }
		$self->get_fields_where([$self->fields], $where, $order);
}

# returns an iterator that generates a record object for each matching row
sub get_records_where_i {
	my ($self, $where, $order) = @_;
	
	return imap { $self->box($_) }
		$self->get_fields_where_i([$self->fields], $where, $order);
}

################################################################################
# lowlevel insert
################################################################################

# returns the number of rows affected by inserting each row
sub insert_fields {
	my ($self, $fields, $rows) = @_;
	
	my ($sth, @order) = $self->_insert_fields_prep($fields);
	my @results;
	foreach my $row (@$rows) {
		push @results, $sth->execute(@$row[@order]);
	}
	$sth->finish;
	return @results;
}

# returns the number of rows affected by inserting each row
sub insert_fields_i {
	my ($self, $fields, $rows_i) = @_;
	
	my ($sth, @order) = $self->_insert_fields_prep($fields);
	my @results;
	until ($rows_i->is_exhausted) {
		push @results, $sth->execute(@{$rows_i->value}[@order]);
	}
	$sth->finish;
	return @results;
}

# helper, returns a prepared statement handle
sub _insert_fields_prep {
	my ($self, $fields) = @_;
	
	# we'll use dummy values to determine bind order
	my %values;
	@values{@$fields} = (0..@$fields-1);
	
	my ($stmt, @order) = $self->sql->insert($self->table, \%values);
	my $sth = $self->dbh->prepare_cached($stmt, undef, 3); # 3: see DBI docs
	return $sth, @order;
}

################################################################################
# inserting records
################################################################################

# returns the number of rows affected by inserting each record
sub insert_records {
	my ($self, $Records) = @_;
	return $self->insert_fields_i([$self->fields], imap { $self->unbox($_) } iarray $Records);
}

# returns the number of rows affected by inserting each record
sub insert_records_i {
	my ($self, $Records_i) = @_;
	return $self->insert_fields_i([$self->fields], imap { $self->unbox($_) } $Records_i);
}

################################################################################
# lowlevel update-where
################################################################################

# execute a single UPDATE by passing a ref to a hash mapping field names to new
# values and a reference to a hash specifying a where clause

# returns number of rows affected by update
sub update_where {
	my ($self, $fieldvals, $where) = @_;
	
	my ($stmt, @bind_vals) = $self->sql->update($self->table, $fieldvals, $where);
	my $sth = $self->dbh->prepare_cached($stmt, undef, 3); # 3 -- see DBI docs
	my $result = $sth->execute(@bind_vals);
	$sth->finish;
	
	return $result;
}

################################################################################
# lowlevel update-fields
################################################################################

# rather than allowing an unrestrained where clause here, we generate one based
# on the value of the keyfields in each row. in this respect, the behavior is
# more like "REPLACE INTO", except that a record with matching keys must already
# exist.

# returns the number of rows affected by updating each row
sub update_fields {
	my ($self, $fields, $rows) = @_;
	
	my ($sth, $val_order, $where_order) = $self->_update_fields_prep($fields);
	my @results;
	foreach my $row (@$rows) {
		push @results, $sth->execute(@$row[@$val_order,@$where_order]);
	}
	$sth->finish;
	return @results;
}

# returns the number of rows affected by updating each row
sub update_fields_i {
	my ($self, $fields, $rows_i) = @_;
	
	my ($sth, $val_order, $where_order) = $self->_update_fields_prep($fields);
	my @results;
	until ($rows_i->is_exhausted) {
		push @results, $sth->execute(@{$rows_i->value}[@$val_order,@$where_order]);
	}
	$sth->finish;
	return @results;
}

# helper, returns a prepared statement handle
sub _update_fields_prep {
	my ($self, $fields) = @_;
	
	# get hashes to pass to update() and where()
	# (dies if any keyfield is missing from @$fields)
	my ($values, $where) = $self->gen_update_hashes($fields);
	
	# do the where clause separately so we get a separate bind list (cute substr trick, huh?)
	my ($stmt, @val_order) = $self->sql->update($self->table, $values);
	(substr($stmt,length($stmt),0), my @where_order) = $self->sql->where($where);
	
	my $sth = $self->dbh->prepare_cached($stmt, undef, 3); # 3: see DBI docs
	return $sth, \@val_order, \@where_order;
}

################################################################################
# updating records
################################################################################

# returns the number of rows affected by updating each record
sub update_records {
	my ($self, $Records) = @_;
	return $self->update_fields_i([$self->fields], imap { $self->unbox($_) } iarray $Records);
}

# returns the number of rows affected by updating each record
sub update_records_i {
	my ($self, $Records_i) = @_;
	return $self->update_fields_i([$self->fields], imap { $self->unbox($_) } $Records_i);
}

################################################################################
# lowlevel delete-where
################################################################################

# execute a single DELETE by passing a ref to a hash specifying a where clause

# returns number of rows affected by delete
sub delete_where {
	my ($self, $where) = @_;
	
	my ($stmt, @bind_vals) = $self->sql->delete($self->table, $where);
	my $sth = $self->dbh->prepare_cached($stmt, undef, 3); # 3 -- see DBI docs
	my $result = $sth->execute(@bind_vals);
	$sth->finish;
	
	return $result;
}

################################################################################
# lowlevel delete-fields
################################################################################

# rather than allowing an unrestrained where clause here, we generate one based
# on the value of the keyfields in each row. this allows us to delete a bunch
# of records with a single statement handle, if what we have is a big list of
# record IDs (i.e. keyfields)

# an alternate approach would be to generate one big WHERE clause by ORing
# together the ANDed keyfields for each record to delete. This has the potential
# to accumulate a huge stmt string, but it's just one execute.

# returns the number of rows affected by deleting each row
sub delete_fields {
	my ($self, $fields, $rows) = @_;
	
	my ($sth, @order) = $self->_delete_fields_prep($fields);
	my @results;
	foreach my $row (@$rows) {
		push @results, $sth->execute(@$row[@order]);
	}
	$sth->finish;
	return @results;
}

# returns the number of rows affected by deleting each row
sub delete_fields_i {
	my ($self, $fields, $rows_i) = @_;
	
	my ($sth, @order) = $self->_delete_fields_prep($fields);
	
	my @results;
	until ($rows_i->is_exhausted) {
		push @results, $sth->execute(@{$rows_i->value}[@order]);
	}
	$sth->finish;
	return @results;
}

# helper, returns a prepared statement handle
sub _delete_fields_prep {
	my ($self, $fields) = @_;
	
	# get hashes to pass to update() and where()
	# (dies if any keyfield is missing from @$fields)
	my (undef, $where) = $self->gen_update_hashes($fields);
	
	# do the where clause separately so we get a separate bind list (cute substr trick, huh?)
	my ($stmt, @order) = $self->sql->delete($self->table, $where);
	
	my $sth = $self->dbh->prepare_cached($stmt, undef, 3); # 3: see DBI docs
	return $sth, @order;
}

################################################################################
# deleting records
################################################################################

# we can pass whole records in here, even though all that's needed to delete is
# the keyfields. will be unboxed, and then _delete_fields_prep will ignore the
# non-keyfields when generating the WHERE clause template.

# returns the number of rows affected by deleting each record
sub delete_records {
	my ($self, $Records) = @_;
	return $self->delete_fields_i([$self->fields], imap { $self->unbox($_) } iarray $Records);
}

# returns the number of rows affected by deleting each record
sub delete_records_i {
	my ($self, $Records_i) = @_;
	return $self->delete_fields_i([$self->fields], imap { $self->unbox($_) } $Records_i);
}

################################################################################
# compatibility methods for old API
################################################################################

# oldapi
sub count {
	my ($self, @keyparts) = @_;
	return $self->count_where($self->keyparts_to_where(@keyparts));
}

# oldapi
sub list {
	my ($self, @keyparts) = @_;
	return $self->list_where($self->keyparts_to_where(@keyparts));
}

# oldapi
sub exists {
	my ($self, @keyparts) = @_;
	return $self->exists_where($self->keyparts_to_where(@keyparts));
}

# oldapi
sub add {
	my ($self, $Record) = @_;
	return $self->insert_records([$Record]);
}

# oldapi
sub get {
	my ($self, @keyparts) = @_;
	return ($self->get_records_where($self->keyparts_to_where(@keyparts)))[0];
}

# oldapi
sub gets {
	my ($self, @keypartsRefList) = @_;
	return map { $self->get_records_where($self->keyparts_to_where(@$_)) } @keypartsRefList;
}

# oldapi (FIXME this is a bad interface)
sub getAll {
	my ($self, @keyparts) = @_;
	
	my $table = $self->table;
	croak "getAll: only supported for the problem_user table"
		unless $table eq "problem" or $table eq "problem_user";
	
	return $self->get_records_where($self->keyparts_to_where(@keyparts));
}

# oldapi
sub put {
	my ($self, $Record) = @_;
	return $self->update_records([$Record]);
}

# oldapi
sub delete {
	my ($self, @keyparts) = @_;
	return $self->delete_fields([$self->keyfields], [\@keyparts]);
}

################################################################################
# utility methods
################################################################################

sub table {
	return shift->{table};
}

sub sql {
	return shift->{sql};
}

sub dbh {
	return shift->{driver}->dbi;
}

sub keyfields {
	return shift->{record}->KEYFIELDS;
}

sub fields {
	return shift->{record}->FIELDS;
}

sub field_data {
	return shift->{record}->FIELD_DATA;
}

sub sql_table_name {
	my ($self) = @_;
	return defined $self->{params}{tableOverride}
		? $self->{params}{tableOverride}
		: $self->table;
}

sub sql_field_name {
	my ($self, $field) = @_;
	return defined $self->{params}{fieldOverride}{$field}
		? $self->{params}{fieldOverride}{$field}
		: $field;
}

sub box {
	my ($self, $values) = @_;
	
	my @names = $self->{record}->FIELDS;
	my %pairs;
	# promoting undef values to empty string. eventually we'd like to stop doing this (FIXME)
	@pairs{@names} = map { defined $_ ? $_ : "" } @$values;
	return $self->{record}->new(%pairs);
}

sub unbox {
	my ($self, $Record) = @_;
	
	# demote empty strings to undef. eventually we'd like to stop doing this (FIXME)
	return [ map { $_=$Record->$_; defined $_ and $_ eq "" ? undef : $_ } $self->{record}->FIELDS ];
}

sub keyparts_to_where {
	my ($self, @keyparts) = @_;
	
	my $table = $self->{table};
	my @keynames = $self->keyfields;
	#croak "too many keyparts for table $table (need at most: @keynames)"
	croak "got ", scalar @keyparts, " keyparts, expected at most ", scalar @keynames, " (@keynames) for table $table"
		if @keyparts > @keynames;
	
	# generate a where clause for the keyparts spec
	my %where;
	
	foreach my $i (0 .. $#keyparts) {
		next if not defined $keyparts[$i]; # undefined keypart == not restrained
		$where{$keynames[$i]} = $keyparts[$i];
	}
	
	return \%where;
}

sub keyparts_list_to_where {
	my ($self, @keyparts_list) = @_;
	
	map { $_ = $self->keyparts_to_where(@$_) } @keyparts_list;
	return \@keyparts_list;
}

sub gen_update_hashes {
	my ($self, $fields) = @_;
	
	# the values for the values hash are the index of each field in the fields list
	my %values;
	@values{@$fields} = (0..@$fields-1);
	
	# the values for the where hash are the index of each keyfield in the fields list
	my @keyfields = $self->keyfields;
	my %where;
	@where{@keyfields} = map { exists $values{$_} ? $values{$_} : die "missing keypart '$_'" } @keyfields;
	
	# don't need to update keyfields, so take them out of the values hash
	delete @values{@keyfields};
	
	return \%values, \%where;
}

1;

#
# BioPerl module for Bio::EnsEMBL::PerlDB::Contig
#
# Cared for by Ewan Birney <birney@sanger.ac.uk>
#
# Copyright Ewan Birney
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::PerlDB::Contig - Pure Perl implementation of contig object

=head1 SYNOPSIS

    $contig = Bio::EnsEMBL::PerlDB::Contig->new();
    
    # $sf is a Bio::SeqFeatureI type object. $seq is a Bio::Seq object

    $contig->add_SeqFeature($sf);
    $contig->seq($seq); 

=head1 DESCRIPTION

A pure perl implementation of a contig object, mainly for database loading.


=head1 CONTACT

Describe contact details here

=head1 APPENDIX

The rest of the documentation details each of the object methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...


package Bio::EnsEMBL::PerlDB::Contig;
use vars qw($AUTOLOAD @ISA);
use strict;
use Bio::EnsEMBL::DB::ContigI;

# Object preamble - inheriets from Bio::Root::RootI
use Bio::Root::RootI;

@ISA = qw(Bio::Root::RootI Bio::EnsEMBL::DB::ContigI);
# new() is inherited from Bio::Root::Object

# _initialize is where the heavy stuff will happen when new is called

sub new {
  my($class,@args) = @_;

  my $self = bless {
      _repeat_array  => [],
      _gene_array    => [],
      _id            => '',
      _version       => '',
      _internal_id   => '',
      _seq_date      => '',
      _embl_offset   => 0,
      _embl_order    => 1,
  }, $class;

  return $self;
}

=head2 get_all_Genes

 Title   : get_all_Genes
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_all_Genes{
   my ($self) = @_;
   
   return @{$self->{'_gene_array'}};
}


=head2 add_Gene

 Title   : add_Gene
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub add_Gene{
   my ($self,$gene) = @_;

   if( !$gene->isa("Bio::EnsEMBL::Gene") ) {
       $self->throw("$gene is a not a Bio::EnsEMBL::Gene type");
   }

   push(@{$self->{'_gene_array'}},$gene);
}

=head2 get_all_RepeatFeatures

 Title   : get_all_RepeatFeatures
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_all_RepeatFeatures{
   my ($self,@args) = @_;

   return @{$self->{'_repeat_array'}};
}

=head2 add_RepeatFeature

 Title   : add_RepeatFeature
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub add_RepeatFeature{
   my ($self,$value) = @_;
   
   if( !ref $value || !$value->isa('Bio::EnsEMBL::Repeat') ) {
       $self->throw("$value is not a repeat");
   }

   push(@{$self->{'_repeat_array'}},$value);
}


=head2 get_all_SeqFeatures

 Title   : get_all_SeqFeatures
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_all_SeqFeatures{
   my ($self,@args) = @_;
   if( defined $self->seq() ) {
       return $self->seq->all_SeqFeatures();
   } else {
       return ();
   }
}

=head2 add_SeqFeatures

 Title   : add_SeqFeatures
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub add_SeqFeatures {
   my ($self,$value) = @_;
   
   if( !ref $value || !$value->isa('Bio::EnsEMBL::SeqFeatureI') ) {
       $self->throw("$value is not a SeqFeature");
   }
   if( defined $self->seq ) {
       $self->seq->add_SeqFeature($value);
   } else { 
       $self->throw("must have a seq loaded before adding features");
   }   
}

=head2 seq

 Title   : seq
 Usage   : $obj->seq($newval)
 Function: 
 Returns : value of seq
 Args    : newvalue (optional)


=cut

sub seq{
    my $obj = shift;
    if( @_ ) {
	my $value = shift;
	if(! $value->isa("Bio::Seq") ) {
	    $obj->throw("$value is not a Bio::Seq!");
	}			

	$obj->{'_seq'} = $value;
	$obj->seq_date(time);
    }
    return $obj->{'_seq'};
    
}

=head2 id

 Title   : id
 Usage   : $obj->id($newval)
 Function: 
 Returns : value of id
 Args    : newvalue (optional)


=cut

sub id{
   my $obj = shift;
   if( @_ ) {
       my $value = shift;
       $obj->{'_id'} = $value;
   }
   return $obj->{'_id'};
   
}

=head2 internal_id

 Title   : internal_id
 Usage   : $obj->internal_id($newval)
 Function: 
 Example : 
 Returns : value of database internal id
 Args    : newvalue (optional)

=cut

sub internal_id {
   my ($self,$value) = @_;

   if( defined $value) {
      $self->{'_internal_id'} = $value;
    }
    return $self->{'_internal_id'};
}

=head2 version

 Title   : version
 Usage   : $obj->version($newval)
 Function: 
 Returns : value of version
 Args    : newvalue (optional)


=cut

sub version{
   my $obj = shift;
   if( @_ ) {
      my $value = shift;
      $obj->{'_version'} = $value;
    }
    return $obj->{'_version'};

}

=head2 primary_seq

  Title    : primary_seq
  Usage    : $obj->primary_seq
  Function :
  Returns  : value of primary_seq
  Args     : 

=cut 

sub primary_seq {
    my ($self) = @_;
    if( defined $self->seq ) {
	return $self->seq->primary_seq;
    }
    return undef;
}

=head2 seq_date

 Title   : seq_date
 Usage   : $contig->seq_date()
 Function: Gives the unix time value of the dna table 
           created datetime field, which indicates
           the original time of the dna sequence data
 Example : $contig->seq_date()
 Returns : unix time
 Args    : none


=cut

sub seq_date{
    my ($self,$value) = @_;    
    if( defined $value && $value ne '' ) {
	$self->{'_seq_date'} = $value;
    }
    return $self->{'_seq_date'};
}

=head2 embl_offset

 Title   : embl_offset
 Usage   : 
 Returns : 
 Args    :


=cut

sub embl_offset{
   my ($self,$value) = @_;
    if( defined $value && $value ne '' ) {
	$self->{'_embl_offset'} = $value;
    }
    return $self->{'_embl_offset'};
}

=head2 embl_order

 Title   : embl_order
 Usage   : 
 Returns : 
 Args    :


=cut

sub embl_order {
   my ($self,$value) = @_;
    if( defined $value && $value ne '' ) {
	$self->{'_embl_order'} = $value;
    }
    return $self->{'_embl_order'};
}

1;

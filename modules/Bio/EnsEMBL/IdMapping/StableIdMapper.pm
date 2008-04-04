package Bio::EnsEMBL::IdMapping::StableIdMapper;

=head1 NAME


=head1 SYNOPSIS


=head1 DESCRIPTION


=head1 METHODS


=head1 LICENCE

This code is distributed under an Apache style licence. Please see
http:#www.ensembl.org/info/about/code_licence.html for details.

=head1 AUTHOR

Patrick Meidl <meidl@ebi.ac.uk>, Ensembl core API team

=head1 CONTACT

Please post comments/questions to the Ensembl development list
<ensembl-dev@ebi.ac.uk>

=cut


use strict;
use warnings;
no warnings 'uninitialized';

use Bio::EnsEMBL::IdMapping::BaseObject;
our @ISA = qw(Bio::EnsEMBL::IdMapping::BaseObject);

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Utils::ScriptUtils qw(path_append);
use POSIX qw(strftime);
use Bio::EnsEMBL::IdMapping::ScoredMappingMatrix;


# instance variables
my %debug_mappings;


sub generate_mapping_session {
  my $self = shift;

  # only run this method once
  return if ($self->mapping_session_date);

  $self->logger->info("Generating new mapping_session...\n");

  $self->mapping_session_date(time);
  $self->mapping_session_date_fmt(strftime("%Y-%m-%d %T",
    localtime($self->mapping_session_date)));
  
  my $s_dba = $self->cache->get_DBAdaptor('source');
  my $s_dbh = $s_dba->dbc->db_handle;
  my $t_dba = $self->cache->get_DBAdaptor('target');
  my $t_dbh = $t_dba->dbc->db_handle;

  # check if mapping_session_id was manually set by the configuration
  my $mapping_session_id = $self->conf->param('mapping_session_id');
  
  if ($mapping_session_id) {
    
    $self->logger->debug("Using manually configured mapping_session_id $mapping_session_id\n", 1);
  
  } else {

    # calculate mapping_session_id from db
    my $sql = qq(SELECT MAX(mapping_session_id) FROM mapping_session);
    $mapping_session_id = $self->fetch_value_from_db($s_dbh, $sql);

    unless ($mapping_session_id) {
      $self->logger->debug("No previous mapping_session found.\n", 1);
    }
    
    # increment last mapping_session_id
    $mapping_session_id++;

    $self->logger->debug("Using mapping_session_id $mapping_session_id\n", 1);
  }

  $self->mapping_session_id($mapping_session_id);

  # write old mapping_session table to a file
  my $i;
  my $fh = $self->get_filehandle('mapping_session.txt', 'tables');

  my $sth1 = $s_dbh->prepare("SELECT * FROM mapping_session");
  $sth1->execute;

  while (my @row = $sth1->fetchrow_array) {
    $i++;
    print $fh join("\t", @row);
    print $fh "\n";
  }

  $sth1->finish;
  
  # append the new mapping_session to the file
  my $release_sql = qq(
    SELECT meta_value FROM meta WHERE meta_key = 'schema_version'
  );
  my $old_release = $self->fetch_value_from_db($s_dbh, $release_sql);
  my $new_release = $self->fetch_value_from_db($t_dbh, $release_sql);
  
  my $assembly_sql = qq(
    SELECT meta_value FROM meta WHERE meta_key = 'assembly.default'
  );
  my $old_assembly = $self->fetch_value_from_db($s_dbh, $assembly_sql);
  my $new_assembly = $self->fetch_value_from_db($t_dbh, $assembly_sql);

  unless ($old_release and $new_release and $old_assembly and $new_assembly) {
    $self->logger->warning("Not all data for new mapping_session found:\n", 1);
    $self->logger->info("old_release: $old_release, new_release: $new_release");
    $self->logger->info("old_assembly: $old_assembly, new_assembly $new_assembly\n", 2);
  }

  print $fh join("\t",
                 $mapping_session_id,
                 $self->conf->param('sourcedbname'),
                 $self->conf->param('targetdbname'),
                 $old_release,
                 $new_release,
                 $old_assembly,
                 $new_assembly,
                 $self->mapping_session_date_fmt);

  print $fh "\n";
  close($fh);
  
  $self->logger->info("Done writing ".++$i." mapping_session entries.\n\n");
}


sub map_stable_ids {
  my $self = shift;
  my $mappings = shift;
  my $type = shift;
  
  unless ($mappings and
          $mappings->isa('Bio::EnsEMBL::IdMapping::MappingList')) {
    throw("Need a Bio::EnsEMBL::IdMapping::MappingList of ${type}s.");
  }

  # generate a new mapping_session and write all mapping_session data to a file
  $self->generate_mapping_session;

  $self->logger->info("== Stable ID mapping for $type...\n\n", 0, 'stamped');

  # check if there are any objects of this type at all
  my %all_sources = %{ $self->cache->get_by_name("${type}s_by_id", 'source') };
  my %all_targets = %{ $self->cache->get_by_name("${type}s_by_id", 'target') };
  unless (scalar(keys %all_sources)) {
    $self->logger->info("No cached ${type}s found.\n\n");
    return;
  }

  my %stats = map { $_ => 0 }
    qw(mapped_known mapped_novel new lost_known lost_novel);

  # create some lookup hashes from the mappings
  my %sources_mapped = ();
  my %targets_mapped = ();
  my %scores_by_target = ();

  foreach my $e (@{ $mappings->get_all_Entries }) {
    $sources_mapped{$e->source} = $e->target;
    $targets_mapped{$e->target} = $e->source;
    $scores_by_target{$e->target} = $e->score;
  }

  # determine starting stable ID for new assignments
  my $new_stable_id = $self->find_highest_stable_id($type);

  #
  # assign mapped and new stable IDs
  #
  foreach my $tid (keys %all_targets) {

    my $t_obj = $all_targets{$tid};
    
    # a mapping exists, assign stable ID accordingly
    if (my $sid = $targets_mapped{$tid}) {
      
      my $s_obj = $all_sources{$sid};

      # set target's stable ID and created_date
      $t_obj->stable_id($s_obj->stable_id);
      $t_obj->created_date($s_obj->created_date);

      # calculate and set version
      $t_obj->version($self->calculate_version($s_obj, $t_obj));

      # change modified_date if version changed
      if ($s_obj->version == $t_obj->version) {
        $t_obj->modified_date($s_obj->modified_date);
      } else {
        $t_obj->modified_date($self->mapping_session_date);
      }

      # create a stable_id_event entry (not for exons)
      unless ($type eq 'exon') {
        my $key = join("\t",
                       $s_obj->stable_id,
                       $s_obj->version,
                       $t_obj->stable_id,
                       $t_obj->version,
                       $self->mapping_session_id,
                       $type,
                       $scores_by_target{$tid}
        );
        $self->add_stable_id_event('new', $key);
      }

      # add to debug hash
      push @{ $debug_mappings{$type} }, [ $sid, $tid, $t_obj->stable_id ];

      # stats
      if ($s_obj->is_known) {
        $stats{'mapped_known'}++;
      } else {
        $stats{'mapped_novel'}++;
      }

    # no mapping was found, assign a new stable ID
    } else {
      
      $new_stable_id = $self->increment_stable_id($new_stable_id);
      $t_obj->stable_id($new_stable_id);
      $t_obj->version(1);
      $t_obj->created_date($self->mapping_session_date);
      $t_obj->modified_date($self->mapping_session_date);

      # create a stable_id_event entry (not for exons)
      unless ($type eq 'exon') {
        my $key = join("\t",
                       '\N',
                       0,
                       $t_obj->stable_id,
                       $t_obj->version,
                       $self->mapping_session_id,
                       $type,
                       0
        );
        $self->add_stable_id_event('new', $key);
      }

      # stats
      $stats{'new'}++;

    }

  }
  
  #
  # deletion events for lost sources
  # 
  my $fh;
  if ($type eq 'gene' or $type eq 'transcript') {
    $fh = $self->get_filehandle("${type}s_lost.txt", 'debug');
  }
  
  foreach my $sid (keys %all_sources) {

    my $s_obj = $all_sources{$sid};
    
    # no mapping exists, add deletion event
    unless ($sources_mapped{$sid}) {
      unless ($type eq 'exon') {
        my $key = join("\t",
                       $s_obj->stable_id,
                       $s_obj->version,
                       '\N',
                       0,
                       $self->mapping_session_id,
                       $type,
                       0
        );
        $self->add_stable_id_event('new', $key);
      }

      # stats
      my $status;
      if ($s_obj->is_known) {
        $stats{'lost_known'}++;
        $status = 'known';
      } else {
        $stats{'lost_novel'}++;
        $status = 'novel';
      }

      # log lost genes and transcripts (for debug purposes)
      #
      # The Java app did this with a separate method
      # (StableIdMapper.dumpLostGeneAndTranscripts()) which also claims to log
      # losses due to merge. Since at that point this data isn't available yet
      # the logging can be done much more efficient here
      if ($type eq 'gene' or $type eq 'transcript') {
        print $fh $s_obj->stable_id, "\t$status\n";
      }
    }
  }

  close($fh) if (defined($fh));

  #
  # write stable IDs to file
  #
  $self->write_stable_ids_to_file($type, \%all_targets);

  # also generate and write stats to file
  $self->generate_mapping_stats($type, \%stats);

  $self->logger->info("Done.\n\n");
}


sub generate_similarity_events {
  my $self = shift;
  my $mappings = shift;
  my $scores = shift;
  my $type = shift;

  # argument checks
  unless ($mappings and
          $mappings->isa('Bio::EnsEMBL::IdMapping::MappingList')) {
    throw('Need a gene Bio::EnsEMBL::IdMapping::MappingList.');
  }

  unless ($scores and
          $scores->isa('Bio::EnsEMBL::IdMapping::ScoredMappingMatrix')) {
    throw('Need a Bio::EnsEMBL::IdMapping::ScoredMappingMatrix.');
  }

  throw("Need a type (gene|transcript|translation).") unless ($type);

  my $mapped;

  #
  # add similarities for mapped entries
  #
  foreach my $e (@{ $mappings->get_all_Entries }) {

    # create lookup hash for mapped sources and targets; we'll need this later
    $mapped->{'source'}->{$e->source} = 1;
    $mapped->{'target'}->{$e->target} = 1;
    
    # loop over all other entries which contain either source or target;
    # add similarity if score is within 2% of this entry (which is the top
    # scorer)
    my @others = @{ $scores->get_Entries_for_target($e->target) };
    push @others, @{ $scores->get_Entries_for_source($e->source) };
    
    while (my $e2 = shift(@others)) {

      # skip self
      next if (($e->source eq $e2->source) and ($e->target eq $e2->target));

      if ($e2->score > ($e->score * 0.98)) {
      
        my $s_obj = $self->cache->get_by_key("${type}s_by_id", 'source',
          $e2->source);
        my $t_obj = $self->cache->get_by_key("${type}s_by_id", 'target',
          $e2->target);
        
        my $key = join("\t",
                       $s_obj->stable_id,
                       $s_obj->version,
                       $t_obj->stable_id,
                       $t_obj->version,
                       $self->mapping_session_id,
                       $type,
                       $e2->score
        );
        $self->add_stable_id_event('similarity', $key);
      
      }
      
      # [todo] add overlap hack here? (see Java code)
      # probably better solution: let synteny rescoring affect this decision
    }

  }

  #
  # similarities for other entries
  #
  foreach my $dbtype (keys %$mapped) {

    # note: $dbtype will be either 'source' or 'target'
    my $m1 = "get_all_${dbtype}s";
    my $m2 = "get_Entries_for_${dbtype}";
    
    foreach my $id (@{ $scores->$m1 }) {
      
      # skip if this is a mapped source/target
      next if ($mapped->{$dbtype}->{$id});
      
      my @entries = sort { $b->score <=> $a->score } @{ $scores->$m2($id) };

      next unless (@entries);

      # skip if top score < 0.7
      my $top_score = $entries[0]->score;
      next if ($top_score < 0.7);

      # add similarities for all entries within 5% of top scorer
      while (my $e = shift(@entries)) {
        
        if ($e->score > ($top_score * 0.95)) {
          
          my $s_obj = $self->cache->get_by_key("${type}s_by_id", 'source',
            $e->source);
          my $t_obj = $self->cache->get_by_key("${type}s_by_id", 'target',
            $e->target);
          
          my $key = join("\t",
                         $s_obj->stable_id,
                         $s_obj->version,
                         $t_obj->stable_id,
                         $t_obj->version,
                         $self->mapping_session_id,
                         $type,
                         $e->score
          );
          $self->add_stable_id_event('similarity', $key);

        }
      }
      
    }
  }
  
}


sub filter_same_gene_transcript_similarities {
  my $self = shift;
  my $transcript_scores = shift;

  # argument checks
  unless ($transcript_scores and
      $transcript_scores->isa('Bio::EnsEMBL::IdMapping::ScoredMappingMatrix')) {
    throw('Need a Bio::EnsEMBL::IdMapping::ScoredMappingMatrix of transcripts.');
  }

  # create a new matrix for the filtered entries
  my $filtered_scores = Bio::EnsEMBL::IdMapping::ScoredMappingMatrix->new(
    -DUMP_PATH   => path_append($self->conf->param('basedir'), 'matrix'),
    -CACHE_FILE  => 'filtered_transcript_scores.ser',
  );

  # lookup hash for all target transcripts
  my %all_targets = map { $_->stable_id => 1 }
    values %{ $self->cache->get_by_name("transcripts_by_id", 'target') };

  my $i = 0;

  foreach my $e (@{ $transcript_scores->get_all_Entries }) {

    my $s_tr = $self->cache->get_by_key('transcripts_by_id', 'source',
      $e->source);
    my $s_gene = $self->cache->get_by_key('genes_by_transcript_id', 'source',
      $e->source);
    my $t_gene = $self->cache->get_by_key('genes_by_transcript_id', 'target',
      $e->target);
    # workaround for caching issue: only gene objects in 'genes_by_id' cache
    # have a stable ID assigned
    #$t_gene = $self->cache->get_by_key('genes_by_id', 'target', $t_gene->id);

    #$self->logger->debug("xxx ".join(":", $s_tr->stable_id, $s_gene->stable_id,
    #  $t_gene->stable_id)."\n");

    # skip if source and target transcript are in same gene, BUT keep events for
    # deleted transcripts
    if (($s_gene->stable_id eq $t_gene->stable_id) and
      $all_targets{$s_tr->stable_id}) {
        $i++;
        next;
    }

    $filtered_scores->add_Entry($e);
  }
  
  $self->logger->debug("Skipped $i same gene transcript mappings.\n");

  return $filtered_scores;
}


sub generate_translation_similarity_events {
  my $self = shift;
  my $mappings = shift;
  my $transcript_scores = shift;

  # argument checks
  unless ($mappings and
          $mappings->isa('Bio::EnsEMBL::IdMapping::MappingList')) {
    throw('Need a gene Bio::EnsEMBL::IdMapping::MappingList.');
  }

  unless ($transcript_scores and
      $transcript_scores->isa('Bio::EnsEMBL::IdMapping::ScoredMappingMatrix')) {
    throw('Need a Bio::EnsEMBL::IdMapping::ScoredMappingMatrix.');
  }

  # create a fake translation scoring matrix
  my $translation_scores = Bio::EnsEMBL::IdMapping::ScoredMappingMatrix->new(
    -DUMP_PATH   => path_append($self->conf->param('basedir'), 'matrix'),
    -CACHE_FILE  => 'translation_scores.ser',
  );

  foreach my $e (@{ $transcript_scores->get_all_Entries }) {
  
    my $s_tl = $self->cache->get_by_key('transcripts_by_id', 'source',
      $e->source)->translation;
    my $t_tl = $self->cache->get_by_key('transcripts_by_id', 'target',
      $e->target)->translation;

    # add an entry to the translation scoring matrix using the score of the
    # corresponding transcripts
    if ($s_tl and $t_tl) {
      $translation_scores->add_score($s_tl->id, $t_tl->id, $e->score);
    }
  }

  # now generate similarity events using this fake scoring matrix
  $self->generate_similarity_events($mappings, $translation_scores,
    'translation');
}


sub calculate_version {
  my $self = shift;
  my $s_obj = shift;
  my $t_obj = shift;

  my $version = $s_obj->version;

  if ($s_obj->isa('Bio::EnsEMBL::IdMapping::TinyExon')) {
    
    # increment version if sequence changed
    $version++ unless ($s_obj->seq eq $t_obj->seq);
  
  } elsif ($s_obj->isa('Bio::EnsEMBL::IdMapping::TinyTranscript')) {
  
    # increment version if spliced exon sequence changed
    $version++ unless ($s_obj->seq_md5_sum eq $t_obj->seq_md5_sum);

  } elsif ($s_obj->isa('Bio::EnsEMBL::IdMapping::TinyTranslation')) {

    # increment version if transcript changed
    my $s_tr = $self->cache->get_by_key('transcripts_by_id', 'source',
      $s_obj->transcript_id);
    my $t_tr = $self->cache->get_by_key('transcripts_by_id', 'target',
      $t_obj->transcript_id);

    $version++ unless ($s_tr->seq_md5_sum eq $t_tr->seq_md5_sum);
    
  } elsif ($s_obj->isa('Bio::EnsEMBL::IdMapping::TinyGene')) {
    
    # increment version if any transcript changed
    my $s_tr_ident = join(":", map { $_->stable_id.'.'.$_->version }
      sort { $a->stable_id cmp $b->stable_id }
        @{ $s_obj->get_all_Transcripts });
    my $t_tr_ident = join(":", map { $_->stable_id.'.'.$_->version }
      sort { $a->stable_id cmp $b->stable_id }
        @{ $t_obj->get_all_Transcripts });

    $version++ unless ($s_tr_ident eq $t_tr_ident);
    
  } else {
    throw("Unknown object type: ".ref($s_obj));
  }

  return $version;
}


sub find_highest_stable_id {
  my $self = shift;
  my $type = shift;

  my $max_stable_id;

  # use stable ID from configuration if set
  if ($max_stable_id = $self->conf->param("starting_${type}_stable_id")) {
    $self->logger->debug("Using pre-configured $max_stable_id as base for new $type stable IDs\n");
    return $max_stable_id;
  }

  my $s_dba = $self->cache->get_DBAdaptor('source');
  my $s_dbh = $s_dba->dbc->db_handle;
  my $sql = qq(SELECT MAX(stable_id) FROM ${type}_stable_id);
  $max_stable_id = $self->fetch_value_from_db($s_dbh, $sql);

  if ($max_stable_id) {
    $self->logger->debug("Using $max_stable_id as base for new $type stable IDs\n");
  } else {
    $self->logger->warning("Can't find highest ${type}_stable_id in source db.\n");
  }

  return $max_stable_id;
}


sub increment_stable_id {
  my $self = shift;
  my $stable_id = shift;

  unless ($stable_id and ($stable_id =~ /ENS([A-Z]{1,4})(\d{11})/)) {
    throw("Unknown or missing stable ID: $stable_id.");
  }

  my $number = $2;
  my $new_stable_id = 'ENS'.$1.(++$number);

  return $new_stable_id;
}


sub write_stable_ids_to_file {
  my $self = shift;
  my $type = shift;
  my $all_targets = shift;
  
  $self->logger->info("Writing ${type} stable IDs to file...\n");

  my $fh = $self->get_filehandle("${type}_stable_id.txt", 'tables');
  
  my @sorted_targets = map { $all_targets->{$_} } sort { $a <=> $b }
    keys %$all_targets;
  
  foreach my $obj (@sorted_targets) {

    # check for missing created and modified dates
    my $created_date = $obj->created_date;
    unless ($created_date) {
      #$self->logger->debug("Missing created_date for target ".
      #  $obj->to_string."\n", 1);
      $created_date = $self->mapping_session_date;
    }
    
    my $modified_date = $obj->modified_date;
    unless ($modified_date) {
      #$self->logger->debug("Missing modified_date for target ".
      #  $obj->to_string."\n", 1);
      $modified_date = $self->mapping_session_date;
    }
    
    my $row = join("\t",
                   $obj->id,
                   $obj->stable_id,
                   $obj->version,
                   strftime("%Y-%m-%d %T", localtime($created_date)),
                   strftime("%Y-%m-%d %T", localtime($modified_date)),
    );

    print $fh "$row\n";
  }

  close($fh);

  $self->logger->info("Done writing ".scalar(@sorted_targets)." entries.\n\n");
}


sub generate_mapping_stats {
  my $self = shift;
  my $type = shift;
  my $stats = shift;

  my $result = ucfirst($type)." mapping results:\n\n";

  my $fmt1 = "%-10s%-10s%-10s%-10s\n";
  my $fmt2 = "%-10s%6.0f    %6.0f    %4.2f%%\n";

  $result .= sprintf($fmt1, qw(TYPE MAPPED LOST PERCENTAGE));
  $result .= ('-'x40)."\n";

  my $mapped_total = $stats->{'mapped_known'} + $stats->{'mapped_novel'};
  my $lost_total = $stats->{'lost_known'} + $stats->{'lost_novel'};
  my $known_total = $stats->{'mapped_known'} + $stats->{'lost_known'};
  my $novel_total = $stats->{'mapped_novel'} + $stats->{'lost_novel'};

  # no split into known and novel for exons
  unless ($type eq 'exon') {
    $result .= sprintf($fmt2, 'known', $stats->{'mapped_known'},
      $stats->{'lost_known'}, $stats->{'mapped_known'}/$known_total*100);
    $result .= sprintf($fmt2, 'novel', $stats->{'mapped_novel'},
      $stats->{'lost_novel'}, $stats->{'mapped_novel'}/$novel_total*100);
  }
  
  $result .= sprintf($fmt2, 'total', $mapped_total, $lost_total,
    $mapped_total/($known_total + $novel_total)*100);

  # log result
  $self->logger->info($result."\n");

  # write result to file
  my $fh = $self->get_filehandle("${type}_mapping_stats.txt", 'stats');
  print $fh $result;
  close($fh);
}


sub dump_debug_mappings {
  my $self = shift;

  foreach my $type (keys %debug_mappings) {

    $self->logger->debug("Writing $type mappings to debug/${type}_mappings.txt...\n");
    
    my $fh = $self->get_filehandle("${type}_mappings.txt", 'debug');

    foreach my $row (@{ $debug_mappings{$type} }) {
      print $fh join("\t", @$row);
      print $fh "\n";
    }

    close($fh);

    $self->logger->debug("Done.\n");
  }
}


sub write_stable_id_events {
  my $self = shift;
  my $event_type = shift;

  throw("Need an event type (new|similarity).") unless ($event_type);

  $self->logger->debug("Writing $event_type stable_id_events to file...\n");

  my $fh = $self->get_filehandle("stable_id_event_${event_type}.txt", 'tables');
  my $i = 0;

  foreach my $event (@{ $self->get_all_stable_id_events($event_type) }) {
    print $fh "$event\n";
    $i++;
  }

  close($fh);
  
  $self->logger->debug("Done writing $i entries.\n");
}


sub add_stable_id_event {
  my ($self, $type, $event) = @_;

  # argument check
  throw("Need an event type (new|similarity).") unless ($type);

  $self->{'stable_id_events'}->{$type}->{$event} = 1;
}


sub get_all_stable_id_events {
  my ($self, $type) = @_;

  # argument check
  throw("Need an event type (new|similarity).") unless ($type);

  return [ keys %{ $self->{'stable_id_events'}->{$type} } ];
}


sub mapping_session_id {
  my $self = shift;
  $self->{'_mapping_session_id'} = shift if (@_);
  return $self->{'_mapping_session_id'};
}


sub mapping_session_date {
  my $self = shift;
  $self->{'_mapping_session_date'} = shift if (@_);
  return $self->{'_mapping_session_date'};
}


sub mapping_session_date_fmt {
  my $self = shift;
  $self->{'_mapping_session_date_fmt'} = shift if (@_);
  return $self->{'_mapping_session_date_fmt'};
}


1;


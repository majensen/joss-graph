#!/usr/bin/env perl
# create cypher statements
# reviews will have a strawman joss_doi
# lone prereviews will have a null joss_doi

use v5.10;
use Try::Tiny;
use Log::Log4perl::Tiny qw/:easy build_channels/;
use JSON::ize;
use Set::Scalar;
use Neo4j::Cypher::Abstract qw/cypher ptn/;
use strict;
use warnings;

my $NORM_TO = 0.95;
my $log = get_logger();
$log->fh( build_channels( file_append => 'minisrv.log' ) );
my $issues;
my $fn = $ARGV[0];
if ($fn) {
  try {
    $issues = J($fn);
  } catch {
    $log->logcroak("Problem loading input json '$fn': $_");
  };
}
else {
  local $/;
  $_ = <>;
  parsej;
  $issues = J();
  if (!scalar keys %$issues) {
    $log->logcarp("Empty json received from STDIN");
    exit 1;
  }
  $log->logcroak("Problem loading input json from STDIN") unless $issues;
  
}

my $iss = Set::Scalar->new( sort {$a<=>$b} keys %$issues );

 my $revs = Set::Scalar->new( grep { $issues->{$_}{title} and $issues->{$_}{title} =~ /^\[REVIEW\]/ } $iss->members );
my $m_revs = Set::Scalar->new( grep { $issues->{$_}{prerev} } $revs->members );
my $m_prerevs = Set::Scalar->new( map { $issues->{$_}{prerev} } $m_revs->members );
my $prerevs = Set::Scalar->new( grep { $issues->{$_}{title} and $issues->{$_}{title} =~ /^\[PRE.REVIEW\]/ } $iss->members );
my $lone_prerevs = $prerevs->difference($m_prerevs);
my $lone_revs = $revs->difference($m_revs);

# other issues are cruft.

my @cypher;

# matched rev/prerevs
my $i=0;
for my $issn (sort {$a<=>$b} $m_revs->members) {
  my $issue = $issues->{$issn};
  unless ($issue) {
    $log->logcarp("No review with issue number $issn");
    next;
  }
  my $url_stem = $issue->{url};
  $url_stem =~ s/[0-9]+$//;
  $issue->{number} = 0+$issue->{number};
  $issue->{title} =~ s/\[[^]]\]:\s*//;
  my $subm_spec = {
    joss_doi => sprintf( "10.21105/joss.%05d", $issn),
    repository => $issue->{info}{repo},
    title => $issue->{title},
#    review_issue => $issue->{url},
    review_issue_number => 0+$issn,
#    prereview_issue => $url_stem.$issue->{prerev},
    prereview_issue_number => 0+$issue->{prerev},
    disposition => ($issue->{paper} ? 'published' : ($issue->{disposition} eq 'submitted' ? 'under_review' : $issue->{disposition})),
  };
  # args: submission, review issue object, prereview issue object
  create_stmts($subm_spec, $issue, $issues->{$issue->{prerev}});
  $log->info("Processed $i issues") unless ($i++) % 100;
}

for my $issn (sort {$a<=>$b} $lone_revs->members) {
  my $issue = $issues->{$issn};
  unless ($issue) {
    $log->logcarp("No review with issue number $issn");
    next;
  }
  $issue->{number} = 0+$issue->{number};
  my $subm_spec = {
    joss_doi => sprintf( "10.21105/joss.%05d", $issn),
    repository => $issue->{info}{repo},
    title => $issue->{title},
#    review_issue => $issue->{url},
    review_issue_number => 0+$issn,
    disposition => ($issue->{disposition} eq 'submitted' ? 'under_review' : $issue->{disposition}),
  };
  create_stmts($subm_spec, $issue, undef);
}

for my $issn (sort {$a<=>$b} $lone_prerevs->members) {
  my $issue = $issues->{$issn};
  unless ($issue) {
    carp $log->logcarp("No review with issue number $issn");
    next;
  }
  $issue->{number} = 0+$issue->{number};  
  my $subm_spec = {
    repository => $issue->{info}{repo},
    title => $issue->{title},
#    prereview_issue => $issue->{url},
    prereview_issue_number => 0+$issn,
    disposition => ($issue->{disposition} eq 'submitted' ? 'review_pending' : $issue->{disposition}),
  };
  create_stmts($subm_spec, undef, $issue);
}

# strip quotes around integers
for (@cypher) {
  s/'([0-9]+)'/$1/g;
  say $_.';';
}

1;

sub create_stmts {
  my ($subm_spec, $rev_issue, $prerev_issue) = @_;
  # submission spec
  my $issue = $rev_issue // $prerev_issue;
  my $sa_spec = {
    handle => $issue->{info}{author}{handle},
    $issue->{info}{author}{name} ?
      (real_name => $issue->{info}{author}{name}) : (),
    $issue->{info}{author}{orcid} ?
      (orcid => $issue->{info}{author}{orcid}) : (),
  };
  # editor spec
  my $ed_spec = { handle => $issue->{info}{editor} };
  # reviewer specs
  my @rev_specs;
  for my $r (@{$issue->{info}{reviewers}}) {
    push @rev_specs, {
      handle => $r,
     };
  }
  # paper spec
  my $p_spec;
  if (my $paper = $issue->{paper}) {
    $p_spec = {
      title => $paper->{title},
      joss_doi => $paper->{joss_doi},
      archive_doi => $paper->{archive_doi},
      published_date => $paper->{published_date},
      volume => 0+$paper->{volume},
      issue => 0+$paper->{issue},
      url => $paper->{url},
    };    
  }

  # create cypher stmts

  # issues
  for my $iss ($rev_issue, $prerev_issue) {
    next unless $iss;
    
    my $mrg_spec = {
      number => 0+$iss->{number},
    };
    my $upd_spec = {
      # body => $iss->{body},
      url => $iss->{url},
      ( $iss->{label_names} ? (labels => join('|',@{$iss->{label_names}})) : () ),
      created_date => $iss->{createdAt},
      closed_date => $iss->{closedAt},
    };
    push @cypher, cypher->merge(ptn->N('i:issue', $mrg_spec))
      ->on_create->set(set_arg('i', $upd_spec))
      ->on_match->set(set_arg('i', $upd_spec));
    
  }
  # submission
  my $mrg_spec = ($subm_spec->{joss_doi} ? {joss_doi => $subm_spec->{joss_doi}} :
		    { prereview_issue_number => $subm_spec->{prereview_issue_number}});
  my $upd_spec = {
    $subm_spec->{review_issue_number} ? (review_issue_number => $subm_spec->{review_issue_number}) : (),
    $subm_spec->{prereview_issue_number} ? (prereview_issue_number => $subm_spec->{prereview_issue_number}) : (),
    $subm_spec->{disposition} ? (disposition => $subm_spec->{disposition}) : (),        
  };
  push @cypher, cypher->merge(ptn->N('s:submission', $mrg_spec))
    ->on_create->set(set_arg('s', $subm_spec))
    ->on_match->set(set_arg('s', $upd_spec));
  if ($rev_issue) {
    push @cypher, cypher
      ->match(ptn->C(ptn->N('s:submission',$mrg_spec),
		     ptn->N('i:issue', {number => $rev_issue->{number}})
		    ))
      ->merge(ptn->N('s')->R('r:has_review_issue')->N('i'));
  }
  if ($prerev_issue) {
    push @cypher, cypher
      ->match(ptn->C(ptn->N('s:submission',$mrg_spec),
		     ptn->N('i:issue', {number => $prerev_issue->{number}})
		    ))
      ->merge(ptn->N('s')->R('r:has_prereview_issue')->N('i'));
  }
				
  
  if ($issue->{topics}) {
    my $topics = renorm($issue->{topics});
    for my $k (keys %$topics) {
      my $q = cypher->match(ptn->C( ptn->N('s:submission', $mrg_spec), ptn->N('t:mtopic', {name => $k})))
	->merge(ptn->N('s')->R('r:has_topic>')->N('t'))
	->set(set_arg('r', { gamma => 0+$topics->{$k} }));
      push @cypher, $q;
    }
  }
  
  #person
  # editor
  if ($ed_spec->{handle}) {
    push @cypher, cypher->merge(ptn->N('e:person', { handle => $ed_spec->{handle} }));
  }
  # submitter
  my ($mrg_sa) = ($sa_spec->{handle} ? { handle => $sa_spec->{handle} } : { orcid => $sa_spec->{orcid} } );
  if (defined [values %$mrg_sa]->[0]) {
    push @cypher, cypher->merge(ptn->N('b:person', $mrg_sa))
      ->on_create->set(set_arg('b',$sa_spec));
  }
  else {
    1;
  }
  # reviewers
  for my $r_spec (@rev_specs) {
    push @cypher, cypher->merge(ptn->N('r:person', { handle => $r_spec->{handle} }));
  }

  # assignment
  # editor <- assign -> submission
  if ($ed_spec->{handle}) {
    push @cypher, cypher->match(ptn->C(ptn->N('e:person',{handle => $ed_spec->{handle}}),
				       ptn->N('s:submission', $mrg_spec)))
      ->merge(ptn->N('e')->R('<:assigned_to')->N('a:assignment', {role => 'editor'})
	       ->R(':assigned_for>')->N('s'));
  }

  # submitter <- assign(as submitter) -> submission
  if (defined [values %$mrg_sa]->[0]) {  
    push @cypher, cypher->match(ptn->C(ptn->N('b:person', $mrg_sa),
				       ptn->N('s:submission', $mrg_spec)))
      ->merge(ptn->N('b')->R('<:assigned_to')->N('a:assignment', {role => 'submitter'})
	       ->R(':assigned_for>')->N('s'));
    
    # submitter <- assign(as author) -> submission
    push @cypher, cypher->match(ptn->C(ptn->N('b:person', $mrg_sa),
				       ptn->N('s:submission', $mrg_spec)))
      ->merge(ptn->N('b')->R('<:assigned_to')->N('a:assignment', {role => 'author'})
	       ->R(':assigned_for>')->N('s'));
  }
  # reviewer <- assign -> submission
  for my $rev_spec (@rev_specs) {
    push @cypher, cypher->match(ptn->C(ptn->N('r:person',{handle => $rev_spec->{handle}}),
				ptn->N('s:submission', $mrg_spec)))
      ->merge(ptn->N('r')->R('<:assigned_to')->N('a:assignment', {role => 'reviewer'})
	       ->R(':assigned_for>')->N('s'));
  }

  # paper node if applicable
  if ($p_spec) {
    my @other_au_specs;
    for my $other (@{$issue->{paper}{authors}}) {
      next if ($other->{orcid} && ($other->{orcid} eq $issue->{info}{author}{orcid}));
      push @other_au_specs,
	{
	  real_name => join(" ", @{$other}{qw/first_name last_name/}),
	  $other->{orcid} ? (orcid => $other->{orcid}) : (),
	};
    }
    push @cypher, cypher->merge(ptn->N('p:paper', { joss_doi => $p_spec->{joss_doi} }))
      ->on_create->set(set_arg('p',$p_spec));
    for my $oth_spec (@other_au_specs) {
      my $mrg_o = ($oth_spec->{orcid} ? {orcid => $oth_spec->{orcid}} : {real_name => $oth_spec->{real_name}});
      push @cypher, cypher->merge(ptn->N('o:person', $mrg_o))
	->on_create->set(set_arg('o',$oth_spec));
      push @cypher, cypher->match(ptn->C(ptn->N('o:person',$mrg_o),
					 ptn->N('s:submission',$mrg_spec)))
	->merge(ptn->N('o')->R('<:assigned_to')
		->N('a:assignment',{role => 'author'})
		->R('>:assigned_for')->N('s'));
    }

    # paper -> submission
    
    push @cypher, cypher->match( ptn->C(ptn->N('p:paper', {joss_doi => $p_spec->{joss_doi}}),
					ptn->N('s:submission', {joss_doi => $subm_spec->{joss_doi}})) )
      ->merge( ptn->N('p')->R(':from_submission>')->N('s') );

  }
  
  return 1;
}


sub set_arg {
  my ($nd,$hash) = @_;
  my $ret = {};
  for (keys %$hash) {
    $ret->{"$nd\.$_"} = $hash->{$_} if defined $hash->{$_};
  }
  return $ret;
}

sub renorm {
  my ($thash) = @_;
  my @desckeys = sort { $thash->{$b} <=> $thash->{$a} } keys %$thash;
  my $cum = 0;
  my @normkeys;
  for my $k (@desckeys) {
    $cum+=$thash->{$k};
    push @normkeys, $k;
    last if $cum >= $NORM_TO;
  }
  my $ret;
  for (@normkeys) {
    $ret->{$_} = $thash->{$_}/$cum;
  }
  return $ret;
}

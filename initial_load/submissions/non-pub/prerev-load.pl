# add non-pub matched review/prereview and lone preview issues as submissions
# create cypher statements
# reviews will have a strawman joss_doi
# lone prereviews will have a null joss_doi

use v5.10;
use Carp qw/carp croak/;
use JSON::ize;
use Set::Scalar;
use Neo4j::Cypher::Abstract qw/cypher ptn/;
use strict;
use warnings;

my $issues = J('npissues.json');
my $matched_prerevs = J('non-pub-prerev.json');

my @revs = sort {$a<=>$b} keys %$matched_prerevs;

my $iss = Set::Scalar->new( keys %$issues );
my $m_revs = Set::Scalar->new(@revs);
my $m_prerevs = Set::Scalar->new( map { $_->{number} } values %$matched_prerevs );
my $d_iss = $iss->difference( $m_revs->union($m_prerevs) );

my $lone_prerevs = Set::Scalar->new( grep { $issues->{$_}{title} and $issues->{$_}{title} =~ /^\[PRE.REVIEW\]/ } $d_iss->members );
my $lone_revs = Set::Scalar->new( grep { $issues->{$_}{title} and $issues->{$_}{title} =~ /^\[REVIEW\]/ } $d_iss->members );
# other issues are cruft.

1;


my @cypher;

# matched rev/prerevs
for my $issn (sort {$a<=>$b} $m_revs->members) {
  my $subm = $issues->{$issn};
  unless ($subm) {
    carp "No review with issue number $issn";
    next;
  }
  my $iss_spec = {
    joss_doi => sprintf( "10.21105/joss.%05d", $issn),
    review_issue => $subm->{url},
    prereview_issue => $matched_prerevs->{$issn}{url},
  };
  create_stmts($subm, $iss_spec);
}

for my $issn (sort {$a<=>$b} $lone_revs->members) {
  my $subm = $issues->{$issn};
  unless ($subm) {
    carp "No review with issue number $issn";
    next;
  }
  my $iss_spec = {
    joss_doi => sprintf( "10.21105/joss.%05d", $issn),
    review_issue => $subm->{url},
  };
  create_stmts($subm, $iss_spec);
}

for my $issn (sort {$a<=>$b} $lone_prerevs->members) {
  my $subm = $issues->{$issn};
  unless ($subm) {
    carp "No review with issue number $issn";
    next;
  }
  my $iss_spec = {
    prereview_issue => $subm->{url},
  };
  create_stmts($subm, $iss_spec);
}

say $_.';' for @cypher;

1;



sub create_stmts {
  my ($subm, $issue_spec) = @_;
  my $subm_status = ($subm->{title} =~ /^\[PRE/) ? 'review_pending' : 'under_review';
  my $s_spec = {
    title => $subm->{title},
    %$issue_spec,
    repository => $subm->{info}{repo},
    disposition => (dispo($subm->{labels}) eq 'submitted') ? $subm_status : dispo($subm->{labels}),
  };
  my $sa_spec = {
    handle => $subm->{info}{author}{handle},
    real_name => $subm->{info}{author}{name},
    $subm->{info}{author}{orcid} ? (orcid => $subm->{info}{author}{orcid}) : (),
   };
  my $ed_spec = { handle => $subm->{info}{editor} };
  my @rev_specs;
  for my $r (@{$subm->{reviewers}}) {
    push @rev_specs, {
      handle => $r,
     };
  }

  # create cypher stmts
  # submission
  my $mrg_spec = ($s_spec->{joss_doi} ? {joss_doi => $s_spec->{joss_doi}} :
		    { prereview_issue => $s_spec->{prereview_issue}});
  push @cypher, cypher->merge(ptn->N('s:submission', $mrg_spec))
    ->on_create->set(set_arg('s', $s_spec));

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
      ->create(ptn->N('e')->R('<:assigned_to')->N('a:assignment', {role => 'editor'})
	       ->R(':assigned_for>')->N('s'));
  }

  # submitter <- assign(as submitter) -> submission
  if (defined [values %$mrg_sa]->[0]) {  
    push @cypher, cypher->match(ptn->C(ptn->N('b:person', $mrg_sa),
				       ptn->N('s:submission', $mrg_spec)))
      ->create(ptn->N('b')->R('<:assigned_to')->N('a:assignment', {role => 'submitter'})
	       ->R(':assigned_for>')->N('s'));
    
    # submitter <- assign(as author) -> submission
    push @cypher, cypher->match(ptn->C(ptn->N('b:person', $mrg_sa),
				       ptn->N('s:submission', $mrg_spec)))
      ->create(ptn->N('b')->R('<:assigned_to')->N('a:assignment', {role => 'author'})
	       ->R(':assigned_for>')->N('s'));
  }
  # review <- assign -> submission
  for my $rev_spec (@rev_specs) {
    push @cypher, cypher->match(ptn->C(ptn->N('r:person',{handle => $rev_spec->{handle}}),
				ptn->N('s:submission', $mrg_spec)))
      ->create(ptn->N('r')->R('<:assigned_to')->N('a:assignment', {role => 'reviewer'})
	       ->R(':assigned_for>')->N('s'));
  }
  return 1;
}

# determine disposition from review labels
sub dispo {
  my ($labels) = @_;
  my $dispo;
  if ( grep /withdrawn/, @$labels ) {
    $dispo = 'withdrawn';
  }
  elsif ( grep /rejected/, @$labels ) {
    $dispo = 'rejected';
  }
  elsif ( grep /paused/, @$labels ) { # otherwise, if paused present, then paused
    $dispo = 'paused';
  }
  elsif ( grep /accepted/, @$labels) {
    $dispo = 'accepted';
  }
  else {
    $dispo = 'submitted'; # update to review_pending, under_review
  }
  return $dispo;
}

sub set_arg {
  my ($nd,$hash) = @_;
  my $ret = {};
  for (keys %$hash) {
    $ret->{"$nd\.$_"} = $hash->{$_} if defined $hash->{$_};
  }
  return $ret;
}

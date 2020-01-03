package JOSS::Crossref;
# reads the crossref.xml for a paper 
# and outputs json
use v5.10;
use utf8::all;
use lib 'lib';
use Try::Tiny;
use Log::Log4perl::Tiny qw/:easy/;
use XML::Twig;
use strict;
use warnings;


my $log = get_logger();

sub new {
  my ($class, $in) = @_;
  my $self = {};
  $self->{_twig} = XML::Twig->new(pretty_print => 'indented');
  bless $self, $class;
  if ($in) {
    $self->slurpfile($in);
  }
  return $self;
}

sub slurpfile {
  my ($self, $in) = @_;
  if (!ref $in) {
    unless ($in =~ /^.*joss\.([0-9]+)\.crossref\.xml/) {
      $log->logcarp("'$in' doesn't look like a JOSS crossref xml file");
      return;
    }
    $self->{_file} = $in;
    try {
      $self->twig->parsefile($in);
    } catch {
      $log->logcroak("Problem opening '$in': $_");
    };
  }
  elsif (ref($in) eq 'Mojo::Message::Response') {
    try {
      $self->twig->parse($in->body);
    } catch {
      $log->logcroak("Problem parsing message body: $_");
    };
  }
  $self->{_root} = $self->twig->root;
  
  $self->get_authors;
  $self->get_pubdate;
  $self->get_title;
  $self->get_review_issue;
  $self->get_vol_issue;
  $self->get_dois;

}

sub twig { shift->{_twig} }
sub root { shift->{_root} }

sub get_authors {
  my ($self) = @_;
  my $r = $self->root;
  if (!$self->{_authors}) {
    for my $au ($r->first_descendant('contributors')->children) {
      my $p;
      next unless $au->has_children;
      try {
	$p->{first_name} = $au->first_child('given_name')->text;
	$p->{last_name} = $au->first_child('surname')->text;
	if (my $ch = $au->first_child('orcid') // $au->first_child('ORCID')) {
	  $p->{orcid} = $ch->text;
	}
      } catch {
	$log->logcroak($_);
      };
      push @{$self->{_authors}}, $p;
    }
  }
  return $self->{_authors};
}

sub get_pubdate {
  my ($self) = @_;
  my $r = $self->root;
  if ( !$self->{_pubdate} ) {
    my $mo = $r->first_descendant('publication_date')->first_child('month')->text;
    my $yr = $r->first_descendant('publication_date')->first_child('year')->text;
    $self->{_pubdate} = "$yr-$mo";
  }
  return $self->{_pubdate};
}

sub get_title {
  my ($self) = @_;
  my $r = $self->root;
  if ( !$self->{_title} ) {
    $self->{_title} = $r->first_descendant('journal_article')->first_child('titles')->first_child->text;
  }
  return $self->{_title};
}

sub get_vol_issue {
  my ($self) = @_;
  my $r = $self->root;
  if ( !$self->{_vol_issue} ) {
    my $vol = $r->first_descendant('journal_issue')->first_descendant('volume')->text;
    my $iss = $r->first_descendant('journal_issue')->first_descendant('issue')->text;
    @{$self->{_vol_issue}}{qw/volume issue/} = ($vol, $iss);
  }
  return $self->{_vol_issue};
}

sub get_review_issue {
  my ($self) = @_;
  my $r = $self->root;
  if ( !$self->{_rev_issue} ) {
    for my $ri ($r->first_descendant('rel:program')->children('rel:related_item')) {
      if ($ri->first_child('rel:description')->text =~ /review issue/) {
	$self->{_rev_issue} = $ri->first_child('rel:inter_work_relation[@relationship-type="hasReview"]')->text;
      }
    }
  }
  return $self->{_rev_issue};
}

sub get_dois {
  my ($self) = @_;
  my $r = $self->root;
  if (!$self->{_dois}) {
    my $adoi;
    my $jdoi = $r->first_descendant('publisher_item')->first_child('identifier[@id_type="doi"]')->text;
    for my $ri ($r->first_descendant('rel:program')->children('rel:related_item')) {
      if ($ri->first_child('rel:description')->text =~ /archive/) {
	$adoi = $ri->first_child('rel:inter_work_relation[@identifier-type="doi"]')->text;
	$adoi =~ s/^.*doi\.org\///;
	$adoi =~ s/[^0-9]*$//;
      }
    }
    my $url = $r->first_descendant('journal_article')->first_descendant('doi_data')->first_child('resource')->text;
    $self->{_dois} = { jdoi => $jdoi, adoi => $adoi, url => $url };
  }
  return $self->{_dois};
}

1;

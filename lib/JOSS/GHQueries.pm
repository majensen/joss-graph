package JOSS::GHQueries;
use v5.10;
use base Exporter;
use Template::Tiny;
use Log::Log4perl::Tiny qw/:easy/;
use strict;
use warnings;


our $tt = Template::Tiny->new();

our @EXPORT = qw( %gh_queries make_qry );
# GitHub GraphQL query >templates< : use with Template::Tiny

our %gh_queries = (
  
  last_issue_number => <<QRY,
{
  organization(login: "openjournals") {
    repository(name: "joss-reviews") {
      issues(last:1) {
        pageInfo {
          endCursor
          startCursor
        }
        nodes {
          number
        }
      }
    }
  }
}
QRY
  last_n_issues => <<QRY, # chunk - chunk size, cursor - before this cursor
  { 
    organization(login:"openjournals") {
      repository(name: "joss-reviews") {
        issues(last:[%- chunk -%], before: [% IF cursor %] "[%- cursor -%]" [% ELSE %] null [% END %]) {
          pageInfo {
            endCursor
            startCursor
          }
          nodes {
            number
            title
            url
            state
            labels(first:20) {
              nodes {
                name
              }
            }
            body
          }
        }
      }
    }
  }
QRY
  issue_by_number => <<QRY, # number
  { 
    organization(login:"openjournals") {
      repository(name: "joss-reviews") {
        issue(number:[%- number -%]) {
          number
          title
          url
          state
          createdAt
          closedAt
          labels(first:20) {
            nodes {
              name
            }
          }
          body
        }
      }
    }
  }
QRY
  issue_body_by_number => <<QRY, # number
  { 
    organization(login:"openjournals") {
      repository(name: "joss-reviews") {
        issue(number:[%- number -%]) {
          body
        }
      }
    }
  }
QRY
  person_deets_for_login => <<QRY,
  {
    user(login: "[%- handle -%]") {
      name
      email
    }
  }
QRY
  prereview_issue_by_review_issue => <<QRY, # number - review issue# 
  {
  organization(login: "openjournals") {
    repository(name: "joss-reviews") {
      issue(number: [%- number -%]) {
        timelineItems(first: 50, itemTypes: CROSS_REFERENCED_EVENT) {
          edges {
            node {
              ... on CrossReferencedEvent {
                source {
                  ... on Issue {
                    number
                    author {
                      login
                    }
                    url
                    title
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
QRY
  issues_since_chunk => <<QRY, # chunk: num recs, cursor: stringified cursor, date: issues since 8601 datetime 
  {
   organization(login: "openjournals") {
    repository(name: "joss-reviews") {
      issues(first:[%- chunk -%], after: [% IF cursor %] "[%- cursor -%]" [% ELSE %] null [% END %], filterBy: { since: "[%- date -%]" }) {
        pageInfo {
          endCursor
          startCursor
        }
        nodes {
           number
           body
        }
      }
    }
  }
 }
QRY
  issues_by_lbl_last_chunk => <<QRY, # chunk: num recs, lbl: pre-review | review
  {
   organization(login: "openjournals") {
    repository(name: "joss-reviews") {
      issues(last:[%- chunk -%],filterBy: { labels: ["[%- lbl -%]"] }) {
        pageInfo {
          endCursor
          startCursor
        }
        nodes {
           number
           title
           createdAt
           body
        }
      }
    }
  }
 }
QRY
  last_n_comments_of_issue => <<QRY,
{
  organization(login: "openjournals") {
    repository(name: "joss-reviews") {
      issue(number: [%- number -%]) {
        comments(last: [%- chunk -%]) {
          nodes {
            body
            author {
                login
            }
          }
        }
      }
    }
  }
}
QRY
  comments_chunk => <<QRY, # number: issue number, chunk: num recs, cursor: stringified cursor
  {
   organization(login: "openjournals") {
    repository(name: "joss-reviews") {
      issue( number: [%- number -%] ) {
        number
        comments(first: [%- chunk -%], after: [% IF cursor %] "[%- cursor -%]" [% ELSE %] null [% END %]) {
          pageInfo {
            startCursor
            endCursor
          }
          nodes {
            author { login }
            url
            createdAt
            editor { login }
            updatedAt
            body
          }
        }
      }
    }
  }
}
QRY
  joss_papers_latest_commit => <<QRY,
{
  organization(login:"openjournals") {
    repository(name:"joss-papers"){
      defaultBranchRef {
        target {
          commitUrl
        }
      }
    }
  }
}
QRY
  master_tree => <<QRY, # user || org - login name, repo - repo name
  {
    [% IF user %] user [% ELSE %] organization [% END %] (login: "[% IF user %][%- user -%][% ELSE %][%- org -%][% END %]") {
      repository(name: "[%- repo -%]") {
        object(expression: "master^{tree}") {
         oid
        }
      }
   }
 }

QRY
  object_tree_entries => <<QRY, # user || org - login name, repo - repo name, oid - object id
  {
    [% IF user %]user[% ELSE %]organization[% END %](login: "[% IF user %][%- user -%][% ELSE %][%- org -%][% END %]") {
      repository(name: "[%- repo -%]") {
        object(oid: "[%- oid -%]") {
        ... on Tree {
          entries {
            name
            type
            oid
          }
        }
      }
   }
 }
}
QRY
  object_blob_text_content => <<QRY, # user || org - login name, repo - repo name, oid - object id
  {
    [% IF user %]user[% ELSE %]organization[% END %](login: "[% IF user %][%- user -%][% ELSE %][%- org -%][% END %]") {
      repository(name: "[%- repo -%]") {
        object(oid: "[%- oid -%]") {
        ... on Blob {
          text
        }
      }
   }
 }
}
QRY
 );

sub make_qry {
  my ($qname, $args) = @_;
  my $q;
  $tt->process( \$gh_queries{$qname}, $args, \$q );
  return $q;
}

1;

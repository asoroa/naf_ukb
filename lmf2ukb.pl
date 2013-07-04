#!/usr/bin/perl

use strict;
use Data::Dumper;
use XML::LibXML;
use File::Basename;

binmode(STDOUT, ':utf8');

use Getopt::Std;

my %opts;

getopts('gde', \%opts);

die "usage $0 [-g] [-d] wn_lmf.xml\n\tRead from wn_lmf.xml. Create wn_lmf_dict.txt and wn_lmf_links.txt\nOptions:\t-d create just the dict (no graph).\n\t\t-g create just the graph (no dict).\n\t\t-e create also external references file.\n"
  unless @ARGV;

my $opt_g = 1;
my $opt_d = 1;
my $opt_e = 0;

if (defined $opts{'d'}) {
  $opt_g = 0;
}

if (defined $opts{'g'}) {
  $opt_d = 0;
}

if (defined $opts{'e'}) {
  $opt_e = 1;
}

die "You can't specify both -g and -d!\n" unless $opt_g || $opt_d;

my ($wn_name, $dir) = fileparse($ARGV[0], qw/.xml .XML/);

my $dict_fname = "$wn_name"."_dict.txt";
my $graph_fname = "$wn_name"."_links.txt";
my $xref_fname = "$wn_name"."_xref.txt";

my $parser = XML::LibXML->new();
my $doc = $parser->parse_file($ARGV[0]);
my $root = $doc->getDocumentElement;

my %D;

my $graph_fh;

my ($lexicon_elem) = $root->findnodes("//Lexicon");
my $src = $lexicon_elem->getAttribute("label");
$src =~ s/\s+/_/g;

if ($opt_g) {
  open($graph_fh, ">$graph_fname") || die "Can't create $graph_fname:$!\n";
  binmode($graph_fh, ':utf8');
  &fill_graph($root, $graph_fh, $src);
}

if($opt_d) {

  open(my $dict_fh, ">$dict_fname") || die "Can't create $dict_fname:$!\n";
  binmode($dict_fh, ':utf8');
  &fill_dict($root, $dict_fh);
}

if($opt_e) {
  open(my $xref_fh, ">$xref_fname") || die "Can't create $dict_fname:$!\n";
  binmode($xref_fh, ':utf8');
  &fill_xref($root, $xref_fh, "${src}_xref");
}


sub fill_dict {

  my ($root, $d_fh) = @_;

  foreach my $le_elem ($root->findnodes("//Lexicon[1]/LexicalEntry")) {
    my $le_id = $le_elem->getAttribute("id");
    my ($lemma_elem) = $le_elem->findnodes("./Lemma");
    my $lemma = $lemma_elem->getAttribute("writtenForm");
    if ($lemma eq "") {
      print STDERR "No lemma in LexicalEntry $le_id\n";
      next;
    }
    $lemma =~ s/\s+/_/g;
    my @Sense_elems = $le_elem->findnodes("./Sense");
    print STDERR "No senses in LexicalEntry $le_id\n" unless @Sense_elems;
    foreach my $sense_elem (@Sense_elems) {
      my $sset = $sense_elem->getAttribute("synset");
      my $pos = (split(/\-/, $sset))[-1];
      # update the dictionary
      push @{ $D{"$lemma"}->{$pos} }, $sset;
    }
  }

  while (my ($k, $v) = each %D) {
    print $d_fh $k;
    foreach my $pos (keys %{ $v }) {
      print $d_fh " ".join(" ", @{ $v->{$pos} });
    }
    print $d_fh "\n";
  }
  close $d_fh;
}

sub fill_graph {

  my($root, $g_fh, $src) = @_;

  foreach my $synset_elem ($lexicon_elem->findnodes("Synset")) {
    my $u_id = $synset_elem->getAttribute("id");
    next unless $u_id;
    foreach my $rel_elem ($synset_elem->findnodes("SynsetRelations/SynsetRelation")) {
      my $v_id = $rel_elem->getAttribute("target");
      next unless $v_id;
      next if ($u_id eq $v_id);
      print $g_fh "u:$u_id v:$v_id";
      print $g_fh " s:$src" if $src;
      print $g_fh "\n";
    }
  }
}

sub fill_xref {

  my($root, $g_fh, $src) = @_;

  foreach my $saxis_elem ($root->findnodes("//SenseAxis")) {
    my ($u_id, $v_id) = map { $_->getAttribute("ID") } $saxis_elem->findnodes("./Target");
    next unless $u_id;
    next unless $v_id;
    next if ($u_id eq $v_id);
    print $g_fh "u:$u_id v:$v_id";
    print $g_fh " s:$src" if $src;
    print $g_fh "\n";
  }
}

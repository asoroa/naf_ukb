naf_ukb
=======

Script to make UKB consume and
produce [NAF](https://github.com/newsreader/NAF) documents. The input must
be a valid NAF document annotated at a POS level (typically, the output of
the ```ixa-pipe-pos``` module). The module uses WSD to perform disambiguation
and includes sense annotations to the lemmas in the document.

Typical usage:
```
cat input.naf | ./naf_ukb.pl -K graph.bin -D dict.txt > output.naf
```

You can also chain the input/output into an ixa-pipes pipeline, for instance:
```
cat guardian.txt | java -jar ixa-pipe-tok-1.8.4-exec.jar tok -l en | ixa-pipe-pos-1.5.0-exec.jar tag -m en-pos-perceptron-autodict01-conll09.bin -lm en-lemma-perceptron-conll09.bin | ./naf_ukb.sh -K graph.bin -D dict.txt
```

## Required parameters ##

the `naf_ukb` script requires two options that specify the location of the
graph and dictionary to be used:

`- K` graph serialization. See section [CREATE GRAPH AND DICTIONARY](#create-graph-and-dictionary)

`- D` dictionary text file.

## Optional parameters ##

`- x` path to `ukb_wsd` executable. Default is './ukb_wsd'

`- m` mapping file for pos mapping. See
section [Regular expression translation](#regular-expression-translation)
for more information on POS mappings.

### Passing options to ukb ###

The `naf_ukb` script eventually calls `ukb_wsd` to perform WSD. This latter
program has command-line options that affect many aspects of the WSD step,
including the algorithm to be used and its parameters
(see
[documentation](https://github.com/asoroa/ukb/blob/master/src/README). Inside
`naf_ukb`, you can set `ukb_wsd` options using the `--` syntax. For
example, this command:

```bash
cat input.naf | ./naf_ukb.pl -K graph.bin -D dict.txt -- --dict_weight --dgraph_dfs --dgraph_rank ppr > output.naf
```

runs `ukb_wsd` using the `--dict_weight --dgraph_dfs --dgraph_rank ppr`
parameters.

### Regular expression translation ###

You may need to transform the POS values of the input document to match
those in WordNet. For this, you can create a document with one
transformation per line, each line having two fields:

```
regex pos
```

all POS values that match the regular expression will be translated to
`pos`. For instance, this is the mapping file for spanish data:

```
A.*	a
V.*	v
N.*	n
S.*	r
```
the first line replaces all pos starting with letter 'A'
(AQ0CP0, AQ0FS0 etc.) to the value 'a'. The matching is case insensitive.

If no posmap is given the app translates default NAF pos values, i.e., it
performs the following mapping:
```
N.*	n
R.*	n
G.*	a
V.*	v
A.*	r
```

# Installing naf_ukb #

You should follow these steps:

## INSTALL UKB ##

Follow the instructions in https://github.com/asoroa/ukb/blob/master/src/INSTALL to install ukb. Alternatively, you can use the pre-compiled binaries available at http://ixa2.si.ehu.es/ukb/

## CREATE GRAPH AND DICTIONARY ##

You have full instructions to compile the graph in
https://github.com/asoroa/ukb/blob/master/src/README (1.2 Compiling the KB).

For the impatient, here is a quick reciple using the file at 

http://ixa2.si.ehu.es/ukb/lkb_sources.tar.bz2

which contains the relations for some versions of WordNet. For instance, the
following commands create a graph based on the relations in WordNet 3.0
(plus gloss relations):

```bash
$ cd ~/user/ukb_wsd
$ wget http://ixa2.si.ehu.es/ukb/lkb_sources.tar.bz2
$ tar xjf lkb_sources.tar.bz2
$ cat lkb_sources/30/*_rels.txt | ./bin/compile_kb -o lkb_sources/wn30g.bin64 -
$ mv lkb_sources/30/wnet30_dict.txt lkb_sources/wn30.lex
```

## INSTALL PERL MODULES ##

ukb_naf needs the XML::LibXML module to properly work. There are some
alternatives, depending on the distribution you are working on.

- debian/ubuntu
```bash
$ sudo apt-get install libxml-libxml-perl
```

- RedHat/CentOS
```bash
$ sudo yum install perl-XML-LibXML
```

## INSTALL ukb_naf ##

We will install ukb_naf in the directory /home/user/ukb_wsd

```bash
$ cd ~/user/ukb_wsd
$ git clone https://github.com/asoroa/naf_ukb.git
```

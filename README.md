naf_ukb
=======

Little script to make UKB consume and produce [NAF](https://github.com/newsreader/NAF) documents.

The input document has to be a valid NAF document that is annotated at a POS
level (typically, the output of the ```ixa-pipe-pos``` module. The module
uses WSD to perform disambiguation and includes sense annotations to the
lemmas in the document.

The most basic usage is to use `run_naf_ukb.sh`script to run
`naf_ukb`. First edit the script and put appropriate values for graph,
dictionary and executable. Then, just run

```
cat input.naf | ./run_naf_ukb.sh > output.naf
```

You can also chain the input/output into an ixa-pipes pipeline, for instance:

```
cat guardian.txt | java -jar ixa-pipe-tok-1.8.4-exec.jar tok -l en | ixa-pipe-pos-1.5.0-exec.jar tag -m en-pos-perceptron-autodict01-conll09.bin -lm en-lemma-perceptron-conll09.bin | ./run_naf_ukb.sh 
```

## Required parameters ##

the `naf_ukb` script requires two options that specify the location of the
graph and dictionary to be used:

`- K` knowledge base binary serialization

`- D` dictionary text file

## Optional parameters ##

`- x` path to ukb_wsd executable. Default is './ukb_wsd'

`- m` mapping file for pos mapping. The file consists on lines with 2 elements:

### Regular_expression translation ###

   and the program translates the pos values matched by the regex with the
   corresponding value. For instance, this is the mapping file for spanish
   data:

```
A.*	a
V.*	v
N.*	n
S.*	r
```
   for instance, the first line replaces all pos starting with letter 'A'
   (AQ0CP0, AQ0FS0 etc) to pos value 'a'. The matching is case insensitive.

   If no posmap is given the app translates default NAF pos values, i.e., it
   performs the following mapping:
```
N.*	n
R.*	n
G.*	a
V.*	v
A.*	r
```
Additional values to the wsd program can be specified after a '--' option.


Installing naf_ukb
==================


You should follow these steps:

## 1) INSTALL UKB ##

Follow the instructions in https://github.com/asoroa/ukb/blob/master/src/INSTALL to install ukb. Alternatively, you can use the pre-compiled binaries available at http://ixa2.si.ehu.es/ukb/

## 2) CREATE GRAPH AND DICTIONARY ##

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

## 3) INSTALL PERL MODULES ##

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

## 4) INSTALL ukb_naf ##

We will install ukb_naf in the directory /home/user/ukb_wsd

```bash
$ cd ~/user/ukb_wsd
$ git clone https://github.com/asoroa/naf_ukb.git
```

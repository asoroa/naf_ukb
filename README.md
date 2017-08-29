naf_ukb
=======

Little script to make UKB consume and produce [NAF](https://github.com/newsreader/NAF) documents.

```
Usage:
./naf_ukb.pl [-x wsd_executable] [-m pos_mapping_file ] -K kbfile.bin -D dict.txt input.naf [-- wsd_executable_options] > output.naf
```

The input document has to be a valid NAF document that is annotated at a POS
level (typically, the output of the ```ixa-pipe-pos``` module. The module
uses WSD to perform disambiguation and includes sense annotations to the
lemmas in the document.

## Required parameters ##

the script requires two options that specify the location of the graph and
dictionary to be used:

-K knowledge base binary serialization
-D dictionary text file

## Optional parameters ##

`- x` path to ukb_wsd executable. Default is './ukb_wsd'

`- m` mapping file for pos mapping. The file consists on lines with 2 elements:

Regular_expression translation

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

## Example ##

The most basic usage is to use `run_naf_ukb.sh`script to run `ukb_naf`. First edit
the script and put appropriate values for graph, dictionary and
executable. Then, just run

```
cat input.naf | ./run_naf_ukb.sh > output.naf
```

You can also chain the input/output into an ixa-pipes pipeline, for instance:

```
cat guardian.txt | java -jar ixa-pipe-tok-1.8.4-exec.jar tok -l en | ixa-pipe-pos-1.5.0-exec.jar tag -m en-pos-perceptron-autodict01-conll09.bin -lm en-lemma-perceptron-conll09.bin | ./run_naf_ukb.sh 
```


Installing naf_ukb
==================

Please take a look to the INSTALL file for installing instructions.

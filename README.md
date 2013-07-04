naf_ukb
=======

Little script to add sense information to NAF input, thus producing new NAF.

Usage:
./naf_ukb.pl [-x wsd_executable] [-m pos_mapping_file ] -K kbfile.bin -D dict.txt naf_input.txt [-- wsd_executable_options]

obligatory options:

-K knowledge base binary serialization
-D dictionary text file

optional options:

-x path to ukb_wsd executable. Default is './ukb_wsd'

-m mapping file for pos mapping. The file consists on lines with 2 elements:

Regular_expression translation

   and the program translates the pos values matched by the regex with the
   corresponding value. For instance, this is the mapping file for spanish
   data:

A.*	a
V.*	v
N.*	n
S.*	r

   for instance, the first line replaces all pos starting with letter 'A'
   (AQ0CP0, AQ0FS0 etc) to pos value 'a'. The matching is case insensitive.

   If no posmap is given the app translates default KAF pos values, i.e., it
   performs the following mapping:

N.*	n
R.*	n
G.*	a
V.*	v
A.*	r


Additional values to the wsd program can be specified after a '--' option.

Example:

The following command annotates the spanish input KAF terms with senses,
mapping the pos values accordingly:

./naf_ukb.pl -K kb.bin -D spdict.txt in.kaf.xml > out.naf.xml

If we want to reduce the number of iterations of PageRank, we can use the
--prank_iter option of 'ukb_wsd' application:

./naf_ukb.pl -M kb.bin -W spdict.txt in.kaf.xml -- --prank_iter 5 > out.naf.xml

Also, we can specify the path to the wsd executable:

./naf_ukb.pl -x /opt/ukb/ukb_wsd -M kb.bin -W spdict.txt in.kaf.xml > out.naf.xml

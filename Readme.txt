

Little script to add sense information to KAF input, thus producing new KAF.

Usage:
./kaf_annotate_senses.pl [-x wsd_executable] [-m pos_mapping_file ] -M kbfile.bin -W dict.txt kaf_input.txt [-- wsd_executable_options]

obligatory options:

-M knowledge base binary serialization
-W dictionary text file

optional options:

-x path to wsd_kyoto executable. Default is './ukb_wsd'

-m mapping file for pos mapping. Until we decide a canonical way to
   represent pos values, the script uses a mapping file. The file consists
   on lines with 2 elements:

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

./kaf_annotate_senses.pl -M kb.bin -W spdict.txt in.kaf.xml > out.kaf.xml


If we want to reduce the number of iterations of PageRank, we can use the
--prank_iter option of 'ukb_wsd' application:

./kaf_annotate_senses.pl -M kb.bin -W spdict.txt in.kaf.xml -- --prank_iter 5 > out.kaf.xml

Also, we can specify the path to the wsd executable:

./kaf_annotate_senses.pl -x /opt/ukb/ukb_wsd -M kb.bin -W spdict.txt in.kaf.xml > out.kaf.xml

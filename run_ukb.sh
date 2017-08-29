#!/bin/sh

# modify line below with the full path where the graph is
graph=path_to_compiled_graph
# modify line below with the full path where the dictionary is
dict=path_to_compiled_dict
# modify line below with the full path where ukb_wsd is
exec=path_to_ukb_wsd

# extra options for UKB. The following is a compromise btw. running time and performance
extraopts="-- --dict_weight --dgraph_dfs --dgraph_rank ppr"

rootDir=$(pwd)
${rootDir}/naf_ukb.pl -x ${exec} -K ${graph} -D ${dict} - ${extraopts}

#!/bin/bash
./build/skywalker --num_runs=10000 --ngpu=1 --s=1 --static=0 --bias=1 --ol=0 --d=10 --dw=1 --full=1 --rw=1 --k=1 --m=4  --umresult=1 --escape=1 --absorbesc=1 --input ../input/wiki-Vote-scc.gr -v
#--full=1 --printresult=1
#../input/email-EuAll-scc.gr
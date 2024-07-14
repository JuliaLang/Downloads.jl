## Setup
- Create a ramdisk with a julia install dmg in it
- From that drive host 4 servers from different processes i.e. `python3 -m http.server 800[0,1,2,3]
- Use this Downloads branch
```
./julia --project=/Users/ian/Documents/GitHub/Downloads.jl -t4,1 -ie "using Downloads"
```

## Results

```
julia> Downloads.benchmark()
┌ Info: step
│   buffersize = 1000
└   sem = 1
  5.883749 seconds (26.15 M allocations: 3.774 GiB, 2.21% gc time, 1118 lock conflicts, 4.16% compilation time: 1% of which was recompilation)
553.5023789465181 MB/s
  4.758695 seconds (25.92 M allocations: 3.762 GiB, 2.04% gc time, 912 lock conflicts)
685.0497694741016 MB/s
  5.678072 seconds (25.95 M allocations: 3.763 GiB, 1.97% gc time, 3016 lock conflicts, 0.38% compilation time: 100% of which was recompilation)
574.132343895396 MB/s
┌ Info: step
│   buffersize = 1000
└   sem = 16
  5.810954 seconds (25.93 M allocations: 3.763 GiB, 2.12% gc time, 1448 lock conflicts)
561.0037395480198 MB/s
  5.773611 seconds (25.93 M allocations: 3.763 GiB, 2.20% gc time, 1403 lock conflicts)
564.6324291633324 MB/s
  5.771598 seconds (25.93 M allocations: 3.763 GiB, 2.25% gc time, 1067 lock conflicts)
564.8285506067783 MB/s
┌ Info: step
│   buffersize = 1000
└   sem = 100
  5.922782 seconds (25.93 M allocations: 3.763 GiB, 2.22% gc time, 1564 lock conflicts)
550.4116384709793 MB/s
  5.834804 seconds (25.93 M allocations: 3.763 GiB, 2.26% gc time, 2090 lock conflicts)
558.7100783602333 MB/s
  5.769028 seconds (25.93 M allocations: 3.763 GiB, 2.28% gc time, 1054 lock conflicts)
565.0802954615928 MB/s
┌ Info: step
│   buffersize = 1000
└   sem = 1000
  5.929784 seconds (25.93 M allocations: 3.763 GiB, 2.27% gc time, 1932 lock conflicts)
549.7612525838088 MB/s
  5.809794 seconds (25.93 M allocations: 3.763 GiB, 2.31% gc time, 1180 lock conflicts)
561.1157419014111 MB/s
  5.792519 seconds (25.93 M allocations: 3.763 GiB, 2.31% gc time, 995 lock conflicts)
562.7894046543192 MB/s
┌ Info: step
│   buffersize = 16000
└   sem = 1
  1.599160 seconds (1.87 M allocations: 3.088 GiB, 7.88% gc time, 5 lock conflicts)
2038.4943507890764 MB/s
  1.965676 seconds (1.87 M allocations: 3.088 GiB, 6.18% gc time, 20 lock conflicts)
1658.4144438741173 MB/s
  1.322875 seconds (1.87 M allocations: 3.088 GiB, 7.38% gc time, 46 lock conflicts)
2464.166130149923 MB/s
┌ Info: step
│   buffersize = 16000
└   sem = 16
  1.317781 seconds (1.87 M allocations: 3.088 GiB, 7.36% gc time, 49 lock conflicts)
2473.644024793349 MB/s
  1.664915 seconds (1.87 M allocations: 3.088 GiB, 6.16% gc time, 35 lock conflicts)
1957.9849075916682 MB/s
  1.281601 seconds (1.87 M allocations: 3.088 GiB, 7.45% gc time, 66 lock conflicts)
2543.577210416132 MB/s
┌ Info: step
│   buffersize = 16000
└   sem = 100
  1.694827 seconds (1.87 M allocations: 3.088 GiB, 5.88% gc time, 23 lock conflicts)
1923.4202420169245 MB/s
  1.369849 seconds (1.87 M allocations: 3.088 GiB, 7.26% gc time, 32 lock conflicts)
2379.7274244294545 MB/s
  1.236951 seconds (1.87 M allocations: 3.088 GiB, 7.68% gc time, 54 lock conflicts)
2635.3758457592057 MB/s
┌ Info: step
│   buffersize = 16000
└   sem = 1000
  1.423548 seconds (1.87 M allocations: 3.088 GiB, 6.70% gc time, 25 lock conflicts)
2289.9031427164573 MB/s
  1.234153 seconds (1.87 M allocations: 3.088 GiB, 6.74% gc time, 13 lock conflicts)
2641.334878079956 MB/s
  1.602283 seconds (1.87 M allocations: 3.088 GiB, 7.47% gc time, 53 lock conflicts)
2034.5040871917106 MB/s
┌ Info: step
│   buffersize = 100000
└   sem = 1
  1.568963 seconds (1.84 M allocations: 3.084 GiB, 14.78% gc time)
2077.7231502084805 MB/s
  1.942786 seconds (1.84 M allocations: 3.084 GiB, 13.95% gc time, 5 lock conflicts)
1677.9497204425104 MB/s
  1.794152 seconds (1.84 M allocations: 3.084 GiB, 13.24% gc time, 1 lock conflict)
1816.9218958346707 MB/s
┌ Info: step
│   buffersize = 100000
└   sem = 16
  1.429467 seconds (1.84 M allocations: 3.084 GiB, 17.38% gc time, 4 lock conflicts)
2280.4594356282614 MB/s
  1.622785 seconds (1.84 M allocations: 3.084 GiB, 14.81% gc time, 4 lock conflicts)
2008.8083572160774 MB/s
  1.360494 seconds (1.84 M allocations: 3.084 GiB, 17.45% gc time, 2 lock conflicts)
2396.0664820249995 MB/s
┌ Info: step
│   buffersize = 100000
└   sem = 100
  1.869941 seconds (1.84 M allocations: 3.084 GiB, 14.60% gc time, 2 lock conflicts)
1743.2965527011731 MB/s
  1.317602 seconds (1.84 M allocations: 3.084 GiB, 18.04% gc time, 7 lock conflicts)
2474.0350439535628 MB/s
  1.234218 seconds (1.84 M allocations: 3.084 GiB, 19.30% gc time, 3 lock conflicts)
2641.164307864563 MB/s
┌ Info: step
│   buffersize = 100000
└   sem = 1000
  1.711810 seconds (1.84 M allocations: 3.084 GiB, 14.85% gc time, 6 lock conflicts)
1904.3553585514867 MB/s
  1.346043 seconds (1.84 M allocations: 3.084 GiB, 17.12% gc time, 3 lock conflicts)
2421.7984149779563 MB/s
  1.329239 seconds (1.84 M allocations: 3.084 GiB, 16.74% gc time, 11 lock conflicts)
2452.4081130336504 MB/s
┌ Info: step
│   buffersize = 1000000
└   sem = 1
  1.912294 seconds (1.63 M allocations: 3.077 GiB, 17.49% gc time, 7 lock conflicts)
1704.7024407168183 MB/s
  1.366684 seconds (1.63 M allocations: 3.076 GiB, 21.46% gc time, 10 lock conflicts)
2385.2127782652974 MB/s
  1.675928 seconds (1.63 M allocations: 3.077 GiB, 20.83% gc time, 4 lock conflicts)
1945.112234655538 MB/s
┌ Info: step
│   buffersize = 1000000
└   sem = 16
  1.180245 seconds (1.63 M allocations: 3.077 GiB, 27.01% gc time, 3 lock conflicts)
2761.9742651353386 MB/s
  1.191021 seconds (1.63 M allocations: 3.076 GiB, 25.92% gc time, 6 lock conflicts)
2737.023180777891 MB/s
  1.170615 seconds (1.63 M allocations: 3.076 GiB, 24.74% gc time, 9 lock conflicts)
2784.7313987201233 MB/s
┌ Info: step
│   buffersize = 1000000
└   sem = 100
  1.201154 seconds (1.63 M allocations: 3.076 GiB, 24.53% gc time, 13 lock conflicts)
2713.8978327570303 MB/s
  1.394596 seconds (1.63 M allocations: 3.076 GiB, 24.09% gc time, 3 lock conflicts)
2337.4895774225756 MB/s
  1.464218 seconds (1.63 M allocations: 3.077 GiB, 21.20% gc time, 4 lock conflicts)
2226.330322206093 MB/s
┌ Info: step
│   buffersize = 1000000
└   sem = 1000
  1.329596 seconds (1.63 M allocations: 3.076 GiB, 25.44% gc time, 7 lock conflicts)
2451.7476692885703 MB/s
  1.282636 seconds (1.63 M allocations: 3.077 GiB, 23.98% gc time, 7 lock conflicts)
2541.5276991869455 MB/s
  1.220083 seconds (1.63 M allocations: 3.076 GiB, 25.35% gc time, 3 lock conflicts)
2671.746536487319 MB/s
┌ Info: step
│   buffersize = 10000000
└   sem = 1
  1.915420 seconds (1.61 M allocations: 3.076 GiB, 20.05% gc time, 2 lock conflicts)
1701.905063454695 MB/s
  1.481441 seconds (1.61 M allocations: 3.076 GiB, 22.17% gc time, 3 lock conflicts)
2200.47336150958 MB/s
  1.334401 seconds (1.61 M allocations: 3.076 GiB, 23.14% gc time, 12 lock conflicts)
2442.910244189441 MB/s
┌ Info: step
│   buffersize = 10000000
└   sem = 16
  1.275077 seconds (1.61 M allocations: 3.076 GiB, 22.80% gc time, 2 lock conflicts)
2556.5795161908536 MB/s
  1.396336 seconds (1.61 M allocations: 3.076 GiB, 22.38% gc time)
2334.5681420427168 MB/s
  1.343448 seconds (1.61 M allocations: 3.076 GiB, 23.44% gc time, 4 lock conflicts)
2426.4792149446557 MB/s
┌ Info: step
│   buffersize = 10000000
└   sem = 100
  1.372080 seconds (1.61 M allocations: 3.076 GiB, 21.59% gc time, 3 lock conflicts)
2375.83635953364 MB/s
  1.528893 seconds (1.61 M allocations: 3.077 GiB, 21.11% gc time, 6 lock conflicts)
2132.1663537772497 MB/s
  1.203104 seconds (1.61 M allocations: 3.076 GiB, 26.36% gc time, 5 lock conflicts)
2709.5014465392405 MB/s
┌ Info: step
│   buffersize = 10000000
└   sem = 1000
  1.310087 seconds (1.61 M allocations: 3.077 GiB, 23.43% gc time, 3 lock conflicts)
2488.2377984378486 MB/s
  1.564185 seconds (1.61 M allocations: 3.077 GiB, 18.97% gc time, 4 lock conflicts)
2084.0614056725813 MB/s
  1.213189 seconds (1.61 M allocations: 3.076 GiB, 26.13% gc time)
2687.0070528956758 MB/s
5×4×3 Array{Float64, 3}:
[:, :, 1] =
  553.502   561.004   550.412   549.761
 2038.49   2473.64   1923.42   2289.9
 2077.72   2280.46   1743.3    1904.36
 1704.7    2761.97   2713.9    2451.75
 1701.91   2556.58   2375.84   2488.24

[:, :, 2] =
  685.05   564.632   558.71   561.116
 1658.41  1957.98   2379.73  2641.33
 1677.95  2008.81   2474.04  2421.8
 2385.21  2737.02   2337.49  2541.53
 2200.47  2334.57   2132.17  2084.06

[:, :, 3] =
  574.132   564.829   565.08   562.789
 2464.17   2543.58   2635.38  2034.5
 1816.92   2396.07   2641.16  2452.41
 1945.11   2784.73   2226.33  2671.75
 2442.91   2426.48   2709.5   2687.01
 ```
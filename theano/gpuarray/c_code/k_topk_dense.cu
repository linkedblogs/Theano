#define RADIX_BITS 4
#define RADIX_SIZE      (1<<RADIX_BITS)
#define RADIX_MASK(n)   ((RADIX_SIZE-1) << (n*RADIX_BITS))
#define RADIX_DIGITS(T) (bitsof(T)/RADIX_BITS)

// works when length on axis is within max allowed threads in block (1024)
KERNEL void k_topk_dense(
        $dims
        // ga_size dims_1, ga_ssize dims_2, ... , dims_$${NDIM}
        $dstv
        // INPUT_TYPE *dstv
        $dstv_strides
        // ga_ssize dstv_strides_0, ga_ssize dstv_strides_1, ... , dstv_strides_$${NDIM}
        $dsti
        // INDEX_TYPE *dsti
        $dsti_strides
        // ga_ssize dsti_strides_0, ga_ssize dsti_strides_1, ... , dsti_strides_$${NDIM}
        ga_ssize k,
        INPUT_TYPE* src,
        $src_strides
        // ga_ssize src_strides_0, ga_ssize src_strides_1, ... , src_strides_$${NDIM}
        ga_size size) {
    LOCAL_MEM ga_int smem[32 * RADIX_SIZE];
    LOCAL_MEM ga_int k2;
    const ga_uint idx = LID_0;
    bool is_topk= (idx < size);
    bool is_topkth = is_topk;
    ga_size out_idx;

    const ga_ubyte warp_id = idx / GA_WARP_SIZE;

    // 0. get the slice for thread block to work on

    ga_size gid = GID_0, gidx;
    $set_slice
    //for(int i=1; i<NDIM; i++) {
        // gidx = gid % dims_$${i};
        // gid /= dims_$${i};
        // dsti = ptr_add(dsti, gidx*dsti_strides_$${i};
        // dstv = ptr_add(dstv, gidx*dstv_strides_$${i};
        // src = ptr_add(src, gidx*src_strides_$${i});
    //}

    // get input and its radix friendly form
    const INPUT_TYPE xval = is_topk ? ptr_at(src, idx*src_strides_0) : (INPUT_TYPE)0;
    radix_t x = RadixConfig<INPUT_TYPE>::convert(xval);

    // resolve negative k
    if (k<0) { x = ~x; k = -k; }
    if (idx==0)
        k2 = k;

    // 1. filter is_topk and is_topkth using radix select

    #pragma unroll
    for (int i=bitsof(INPUT_TYPE)-RADIX_BITS; i>=0; i-=RADIX_BITS) {
        const ga_int digit = Bitfield<radix_t>::get(x, i, RADIX_BITS);
        /*ga_int digit = (x>>i) & (RADIX_SIZE-1);*/
        // count within warp
        #pragma unroll
        for (int bin=0; bin<RADIX_SIZE; ++bin) {
            bool vote = (bin == digit) && is_topkth;
            ga_uint votes = __ballot(vote);
            if (lane_id()==0)
                smem[bin + RADIX_SIZE*warp_id] = __popc(votes);
        }
        local_barrier();
        // sum counts across all warps
        if (idx < RADIX_SIZE) {
            ga_int sum = smem[idx];
            #pragma unroll
            for(int w=RADIX_SIZE; w<LDIM_0*RADIX_SIZE / GA_WARP_SIZE; w+=RADIX_SIZE)
                sum += smem[idx + w];
            smem[idx] = sum;
        }
        local_barrier();

        // find the bucket and update k2
        // smem[:RADIX_SIZE:-1] = k2 - cumsum(smem[:RADIX_SIZE-1:-1])
        if (idx == 0) {
            ga_int sum = k2;
            #pragma unroll
            for (int bin=RADIX_SIZE-1; bin>=0; --bin) {
                sum -= smem[bin];
                smem[bin] = sum;
                k2 = (sum > 0) ? sum : k2;
            }
            smem[RADIX_SIZE] = 1;
        }
        local_barrier();

        if (is_topkth) {
            is_topk &= (smem[digit+1] > 0);
            is_topkth &= (smem[digit] <= 0) && (smem[digit+1] > 0);
        }
        local_barrier();
    }

    // set k2 as number of exceeding values
    if (idx==0) {
        #pragma unroll
        for (int bin=RADIX_SIZE-1; bin>=0; --bin) {
            if (smem[bin] <= 0)
                break;
            k2 = smem[bin];
        }
    }
    local_barrier();

    // 2. find the index of output array, if exists

    if (k2 != 0) {
        // top_kth value may not be unique, so we need to
        // perform binary cumsum on is_topkth to drop exceeding top-kth values
        out_idx = binary_cumsum_exclusive(idx, warp_id, smem, is_topkth);
        if ((out_idx >= k2) && is_topkth)
            is_topk = false;
        local_barrier();
    }

    // perform binary cumsum on is_topk to determine the indices to put result
    out_idx = binary_cumsum_exclusive(idx, warp_id, smem, is_topk);

    if (is_topk) {
#if WRITE_VALUE == 1
        ptr_at(dstv, out_idx * dstv_strides_0) = xval;
#endif
#if WRITE_INDEX == 1
        ptr_at(dsti, out_idx * dsti_strides_0) = (INDEX_TYPE)idx;
#endif
    }
}

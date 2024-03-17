# cython: language_level=3
# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import numpy as np

cimport cython
cimport numpy as np

from libc.stdint cimport int32_t, int64_t
from libcpp cimport bool as bool_t

ctypedef int64_t DTYPE_t

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cpdef list batch_by_size_vec(
    np.ndarray[int64_t, ndim=1] indices,
    np.ndarray[int64_t, ndim=1] num_tokens_vec,
    int64_t max_tokens,
    int64_t max_sentences,
    int32_t bsz_mult,
):
    if indices.shape[0] == 0:
        return []

    assert max_tokens <= 0 or np.max(num_tokens_vec) <= max_tokens, (
        f"Sentences lengths should not exceed max_tokens={max_tokens}"
    )

    cdef int32_t indices_len = indices.shape[0]
    cdef np.ndarray[int32_t, ndim=1] batches_ends = \
            np.zeros(indices_len, dtype=np.int32)
    cdef int32_t[:] batches_ends_view = batches_ends
    cdef int64_t[:] num_tokens_view = num_tokens_vec

    cdef int32_t pos = 0
    cdef int32_t new_batch_end = 0

    cdef int64_t new_batch_max_tokens = 0
    cdef int32_t new_batch_sentences = 0
    cdef int64_t new_batch_num_tokens = 0

    cdef bool_t overflow = False
    cdef bool_t size_matches_with_bsz_mult = False

    cdef int32_t batches_count = 0
    cdef int32_t batch_start = 0
    cdef int64_t tail_max_tokens = 0
    cdef int64_t batch_max_tokens = 0

    for pos in range(indices_len):
        # At every pos we keep stats about the last complete batch [batch_start:batch_end),
        #      and tail [batch_end:pos].
        # 1) Every time when (batch + tail) forms a valid batch
        #      (according to max_tokens, max_sentences and bsz_mult) we append tail to batch.
        # 2) When (batch+tail) violates max_tokens or max_sentences constraints
        #      we finalize running batch, and tail becomes a new batch.
        # 3) There is a corner case when tail also violates constraints.
        #      In that situation [batch_end:pos-1] (tail without the current pos)
        #      gets added to the finalized batches, while [pos:pos] becomes a new tail.
        #
        # Important: For the sake of performance try to avoid using function calls within this loop.

        tail_max_tokens = tail_max_tokens \
                            if tail_max_tokens > num_tokens_view[pos] \
                            else num_tokens_view[pos]
        new_batch_end = pos + 1
        new_batch_max_tokens = batch_max_tokens \
                                if batch_max_tokens > tail_max_tokens \
                                else tail_max_tokens
        new_batch_sentences = new_batch_end - batch_start
        new_batch_num_tokens = new_batch_sentences * new_batch_max_tokens

        overflow = (new_batch_sentences > max_sentences > 0 or
                    new_batch_num_tokens > max_tokens > 0)
        size_matches_with_bsz_mult = (new_batch_sentences < bsz_mult or
                                      new_batch_sentences % bsz_mult == 0)

        if overflow:
            tail_num_tokens = tail_max_tokens * \
                    (new_batch_end - batches_ends_view[batches_count])
            tail_overflow = tail_num_tokens > max_tokens > 0
            # In case of a tail overflow finalize two batches
            if tail_overflow:
                batches_count += 1
                batches_ends_view[batches_count] = pos
                tail_max_tokens = num_tokens_view[pos]
            batch_start = batches_ends_view[batches_count]
            batches_count += 1
            new_batch_max_tokens = tail_max_tokens

        if overflow or size_matches_with_bsz_mult:
            batches_ends_view[batches_count] = new_batch_end
            batch_max_tokens = new_batch_max_tokens
            tail_max_tokens = 0
    if batches_ends_view[batches_count] != indices_len:
        batches_count += 1
    # Memory and time-efficient split
    return np.split(indices, batches_ends[:batches_count])
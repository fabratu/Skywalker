/*
 * @Description: just perform RW
 * @Date: 2020-11-30 14:30:06
 * @LastEditors: Pengyu Wang
 * @LastEditTime: 2022-03-03 22:46:47
 * @FilePath: /skywalker/src/offline_walk.cu
 */
#include "app.cuh"

__global__ void sample_kernel_escape(Walker *walker, float ratio) {
  Jobs_result<JobType::RW, uint> &result = walker->result;
  gpu_graph *graph = &walker->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);

  // TODO: add state for num runs
  size_t idx_i = TID;
  uint src = graph->adjsrc[idx_i];
  uint k = graph->adjk[idx_i];

  if (idx_i < result.size) {
    // printf("TID: %d, Src: %d (Degree: %d), Current: %d\n", (uint)idx_i, graph->adjsrc[TID], graph->getDegree(graph->adjsrc[TID]), graph->adjk[TID]);

    uint currentDegree = graph->getDegree(src);
    assert(currentDegree > 0);

    size_t numRuns = walker->num_runs / currentDegree;

    uint divider = (uint)1.0/ratio;
    if (divider > currentDegree)
      numRuns = divider; 

    uint sumPhiLocal = 0;
    
    for (size_t i = 0; i < numRuns; i++) {
      uint current = k;
      currentDegree = graph->getDegree(current);
      do {
        if(current == src) {
          sumPhiLocal += 1;
          break;
        }
        Vector_virtual<uint> alias;
        Vector_virtual<float> prob;
        alias.Construt(
            graph->alias_array + graph->xadj[current] - graph->local_vtx_offset,
            currentDegree);
        prob.Construt(
            graph->prob_array + graph->xadj[current] - graph->local_vtx_offset,
            currentDegree);
        alias.Init(currentDegree);
        prob.Init(currentDegree);
        const uint target_size = 1;
        if (target_size < currentDegree) {
          //   int itr = 0;
          // for (size_t i = 0; i < target_size; i++) {
          int col = (int)floor(curand_uniform(&state) * currentDegree);
          float p = curand_uniform(&state);
          uint candidate;
          if (p < prob[col])
            candidate = col;
          else
            candidate = alias[col];
            current = graph->getOutNode(current, candidate);
          // }
        } else if (currentDegree == 0) {
          result.alive[idx_i] = 0;
          break;
        } else {
          current = graph->getOutNode(current, 0);
        }
      } while (result.alive[idx_i] != 0 && current != graph->maxD);
    } 
  }
}

__global__ void sample_kernel_static_buffer(Walker *walker) {
  Jobs_result<JobType::RW, uint> &result = walker->result;
  gpu_graph *graph = &walker->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);
  __shared__ matrixBuffer<BLOCK_SIZE, 31, uint> buffer;
  buffer.Init();

  size_t idx_i = TID;
  if (idx_i < result.size) {
    result.length[idx_i] = result.hop_num - 1;
    uint src_id;
    // bool alive = true;
    coalesced_group warp = coalesced_threads();
    for (uint current_itr = 0; current_itr < result.hop_num - 1;
         current_itr++) {
      // coalesced_group active = coalesced_threads();
      if (result.alive[idx_i] != 0) {
        Vector_virtual<uint> alias;
        Vector_virtual<float> prob;
        src_id = current_itr == 0 ? result.GetData(current_itr, idx_i) : src_id;
        uint src_degree = graph->getDegree((uint)src_id);
        alias.Construt(
            graph->alias_array + graph->xadj[src_id] - graph->local_vtx_offset,
            src_degree);
        prob.Construt(
            graph->prob_array + graph->xadj[src_id] - graph->local_vtx_offset,
            src_degree);
        alias.Init(src_degree);
        prob.Init(src_degree);
        const uint target_size = 1;

        if (target_size < src_degree) {
          int col = (int)floor(curand_uniform(&state) * src_degree);
          float p = curand_uniform(&state);
          uint candidate;
          if (p < prob[col])
            candidate = col;
          else
            candidate = alias[col];
          uint next_src = graph->getOutNode(src_id, candidate);
          // if (idx_i == 1) printf("%u adding1 %u \n", idx_i, next_src);
          buffer.Set(next_src);
          src_id = next_src;
        } else if (src_degree == 0) {
          result.alive[idx_i] = 0;
          result.length[idx_i] = current_itr;
          // buffer.Finish();
          // return;
        } else {
          uint next_src = graph->getOutNode(src_id, 0);
          buffer.Set(next_src);
          src_id = next_src;
          // if (idx_i == 1) printf("%u adding %u \n", idx_i, next_src);
        }
      }
      warp.sync();
      buffer.CheckFlush(result.data + result.hop_num * idx_i, current_itr,
                        warp);
    }
    warp.sync();
    buffer.Flush(result.data + result.hop_num * idx_i, 0, warp);
  }
}
// 48 kb , 404 per sampler
__global__ void sample_kernel_static(Walker *walker) {
  Jobs_result<JobType::RW, uint> &result = walker->result;
  gpu_graph *graph = &walker->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);

  size_t idx_i = TID;
  if (idx_i < result.size) {
    result.length[idx_i] = result.hop_num - 1;
    for (uint current_itr = 0; current_itr < result.hop_num - 1;
         current_itr++) {
      if (result.alive[idx_i] != 0) {
        Vector_virtual<uint> alias;
        Vector_virtual<float> prob;
        uint src_id = result.GetData(current_itr, idx_i);
        uint src_degree = graph->getDegree((uint)src_id);
        alias.Construt(
            graph->alias_array + graph->xadj[src_id] - graph->local_vtx_offset,
            src_degree);
        prob.Construt(
            graph->prob_array + graph->xadj[src_id] - graph->local_vtx_offset,
            src_degree);
        alias.Init(src_degree);
        prob.Init(src_degree);
        const uint target_size = 1;
        if (target_size < src_degree) {
          //   int itr = 0;
          // for (size_t i = 0; i < target_size; i++) {
          int col = (int)floor(curand_uniform(&state) * src_degree);
          float p = curand_uniform(&state);
          uint candidate;
          if (p < prob[col])
            candidate = col;
          else
            candidate = alias[col];
          *result.GetDataPtr(current_itr + 1, idx_i) =
              graph->getOutNode(src_id, candidate);
          // }
        } else if (src_degree == 0) {
          result.alive[idx_i] = 0;
          result.length[idx_i] = current_itr;
          break;
        } else {
          *result.GetDataPtr(current_itr + 1, idx_i) =
              graph->getOutNode(src_id, 0);
        }
      }
    }
  }
}

__global__ void sample_kernel(Walker *walker) {
  Jobs_result<JobType::RW, uint> &result = walker->result;
  gpu_graph *graph = &walker->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);

  for (size_t idx_i = TID; idx_i < result.size;
       idx_i += gridDim.x * blockDim.x) {
    result.length[idx_i] = result.hop_num - 1;
    for (uint current_itr = 0; current_itr < result.hop_num - 1;
         current_itr++) {
      if (result.alive[idx_i] != 0) {
        Vector_virtual<uint> alias;
        Vector_virtual<float> prob;
        uint src_id = result.GetData(current_itr, idx_i);
        uint src_degree = graph->getDegree((uint)src_id);
        alias.Construt(
            graph->alias_array + graph->xadj[src_id] - graph->local_vtx_offset,
            src_degree);
        prob.Construt(
            graph->prob_array + graph->xadj[src_id] - graph->local_vtx_offset,
            src_degree);
        alias.Init(src_degree);
        prob.Init(src_degree);
        const uint target_size = 1;
        if (target_size < src_degree) {
          //   int itr = 0;
          // for (size_t i = 0; i < target_size; i++) {
          int col = (int)floor(curand_uniform(&state) * src_degree);
          float p = curand_uniform(&state);
          uint candidate;
          if (p < prob[col])
            candidate = col;
          else
            candidate = alias[col];
          *result.GetDataPtr(current_itr + 1, idx_i) =
              graph->getOutNode(src_id, candidate);
          printf("Thread: %d edge: %d -> %d\n",TID, src_id, graph->getOutNode(src_id, candidate));
          // }
        } else if (src_degree == 0) {
          result.alive[idx_i] = 0;
          result.length[idx_i] = current_itr;
          break;
        } else {
          *result.GetDataPtr(current_itr + 1, idx_i) =
              graph->getOutNode(src_id, 0);
        }
      }
    }
  }
}

static __global__ void print_result(Walker *walker) {
  walker->result.PrintResult();
}

float OfflineWalk(Walker &walker) {
  LOG("%s\n", __FUNCTION__);
  int device;
  cudaDeviceProp prop;
  cudaGetDevice(&device);
  cudaGetDeviceProperties(&prop, device);
  int n_sm = prop.multiProcessorCount;

  Walker *sampler_ptr;
  // printf("OfflineWalk xadj:\n");
  // for(size_t i = 0; i < 200; i++) {
  //   printf("%d, ", walker.ggraph.xadj[i]);
  // }
  // printf("\n\n");
  // printf("OfflineWalk adjsrc:\n");
  // for(size_t i = 0; i < 200; i++) {
  //   printf("%d, ", walker.ggraph.adjsrc[i]);
  // }
  // printf("\n\n");
  // printf("OfflineWalk adjk:\n");
  // for(size_t i = 0; i < 200; i++) {
  //   printf("%d, ", walker.ggraph.adjk[i]);
  // }
  // printf("\n\n");
  MyCudaMalloc(&sampler_ptr, sizeof(Walker));
  CUDA_RT_CALL(
      cudaMemcpy(sampler_ptr, &walker, sizeof(Walker), cudaMemcpyHostToDevice));
  double start_time, total_time;
  // init_kernel_ptr<<<1, 32, 0, 0>>>(sampler_ptr,true);
  BindResultKernel<<<1, 32, 0, 0>>>(sampler_ptr);
  // allocate global buffer
  int block_num = n_sm * FLAGS_m;
  CUDA_RT_CALL(cudaDeviceSynchronize());
  CUDA_RT_CALL(cudaPeekAtLastError());
  start_time = wtime();
#ifdef check
  sample_kernel<<<1, BLOCK_SIZE, 0, 0>>>(sampler_ptr);
#else
  if (FLAGS_static) {
    if (FLAGS_buffer)
      // sample_kernel_static_buffer<<<1, 32, 0, 0>>>(sampler_ptr);
      sample_kernel_static_buffer<<<walker.num_seed / BLOCK_SIZE + 1,
                                    BLOCK_SIZE, 0, 0>>>(sampler_ptr);
    else
      sample_kernel_static<<<walker.num_seed / BLOCK_SIZE + 1, BLOCK_SIZE, 0,
                             0>>>(sampler_ptr);
  } else if (FLAGS_escape) {
    LOG("Escape\n", __FUNCTION__);
    sample_kernel_escape<<<walker.num_seed / BLOCK_SIZE + 1, BLOCK_SIZE, 0,
                             0>>>(sampler_ptr, FLAGS_ratio);
  } else
    sample_kernel<<<block_num, BLOCK_SIZE, 0, 0>>>(sampler_ptr);
#endif
  CUDA_RT_CALL(cudaDeviceSynchronize());
  // CUDA_RT_CALL(cudaPeekAtLastError());
  total_time = wtime() - start_time;
#pragma omp barrier
  LOG("Device %d sampling time:\t%.6f ratio:\t %.2f MSEPS\n",
      omp_get_thread_num(), total_time,
      static_cast<float>(walker.result.GetSampledNumber() / total_time /
                         1000000));
  walker.sampled_edges = walker.result.GetSampledNumber();
  LOG("sampled_edges %d\n", walker.sampled_edges);
  if (FLAGS_printresult) print_result<<<1, 32, 0, 0>>>(sampler_ptr);
  CUDA_RT_CALL(cudaDeviceSynchronize());
  return total_time;
}


#ifndef _GPU_GRAPH_H_
#define _GPU_GRAPH_H_
#include <algorithm>
#include <iostream>

#include "graph.cuh"
#include "sampler_result.cuh"

DECLARE_bool(umgraph);
DECLARE_bool(gmgraph);
DECLARE_bool(hmgraph);
DECLARE_int32(gmid);

DECLARE_bool(ol);
DECLARE_bool(weight);
DECLARE_bool(randomweight);
DECLARE_bool(pf);
DECLARE_bool(ab);
DECLARE_double(pfr);
DECLARE_bool(absorbphik);
// typedef uint edge_t;
// typedef unsigned int vtx_t;
// typedef float weight_t;
typedef unsigned char bit_t;

#define INFTY (int)-1
#define BIN_SZ 64

enum class BiasType { Weight = 0, Degree = 1 };

// template<BiasType bias=BiasType::Weight>
class gpu_graph {
 public:
  vtx_t *adjncy;
  weight_t *adjwgt = nullptr;
  vtx_t *adjsrc = nullptr;
  vtx_t *adjk = nullptr;
  edge_t *xadj;
  vtx_t *degree_list;
  uint *outDegree;

  float *prob_array;
  uint *alias_array;
  char *valid;

  edge_t vtx_num;
  edge_t edge_num;
  edge_t avg_degree;
  uint MaxDegree;
  uint maxD;
  uint maxInD;
  uint device_id;

  Jobs_result<JobType::RW, uint> *result;
  uint local_vtx_offset = 0;
  uint local_edge_offset = 0;
  uint local_vtx_num = 0;
  uint local_edge_num = 0;
  // sample_result *result2;
  // BiasType bias;

  // float (gpu_graph::*getBias)(uint);

 public:
  __device__ __host__ gpu_graph() {
    // #if defined(__CUDA_ARCH__)

    // #else
    //     Free();
    // #endif
  }
  gpu_graph(Graph *ginst, uint _device_id = 0) : device_id(_device_id) {
    LOG("Do we get here?\n");
    int dev_id = omp_get_thread_num();
    CUDA_RT_CALL(cudaSetDevice(dev_id));

    vtx_num = ginst->numNode;
    edge_num = ginst->numEdge;
    // printf("vtx_num: %d\t edge_num: %d\n", vtx_num, edge_num);
    avg_degree = ginst->numEdge / ginst->numNode;

    if (FLAGS_umgraph) {
      LOG("UMGraph\n");
      CUDA_RT_CALL(MyCudaMallocManaged(&xadj, (vtx_num + 1) * sizeof(edge_t)));
      CUDA_RT_CALL(MyCudaMallocManaged(&adjncy, edge_num * sizeof(vtx_t)));
      if (FLAGS_weight || FLAGS_randomweight)
        CUDA_RT_CALL(MyCudaMallocManaged(&adjwgt, edge_num * sizeof(weight_t)));
      if (FLAGS_absorbphik) {
        CUDA_RT_CALL(MyCudaMallocManaged(&adjsrc, edge_num * sizeof(vtx_t)));
        CUDA_RT_CALL(MyCudaMallocManaged(&adjk, edge_num * sizeof(vtx_t)));
      }
    }
    if (FLAGS_gmgraph) {
      LOG("GMGraph\n");
      CUDA_RT_CALL(cudaSetDevice(FLAGS_gmid));
      CUDA_RT_CALL(MyCudaMalloc(&xadj, (vtx_num + 1) * sizeof(edge_t)));
      CUDA_RT_CALL(MyCudaMalloc(&adjncy, edge_num * sizeof(vtx_t)));
      if (FLAGS_weight || FLAGS_randomweight)
        CUDA_RT_CALL(MyCudaMalloc(&adjwgt, edge_num * sizeof(weight_t)));
      if (FLAGS_absorbphik) {
        CUDA_RT_CALL(MyCudaMalloc(&adjsrc, edge_num * sizeof(vtx_t)));
        CUDA_RT_CALL(MyCudaMalloc(&adjk, edge_num * sizeof(vtx_t)));
      }

      CUDA_RT_CALL(cudaSetDevice(dev_id));
      if (dev_id != FLAGS_gmid) {
        CUDA_RT_CALL(cudaDeviceEnablePeerAccess(FLAGS_gmid, 0));
      }
    }
    if (FLAGS_hmgraph) {
      LOG("HMGraph\n");
      CUDA_RT_CALL(cudaMallocHost(&xadj, (vtx_num + 1) * sizeof(edge_t)));
      CUDA_RT_CALL(cudaMallocHost(&adjncy, edge_num * sizeof(vtx_t)));
      if (FLAGS_weight || FLAGS_randomweight)
        CUDA_RT_CALL(cudaMallocHost(&adjwgt, edge_num * sizeof(weight_t)));
      if (FLAGS_absorbphik) {
        CUDA_RT_CALL(cudaMallocHost(&adjsrc, edge_num * sizeof(vtx_t)));
        CUDA_RT_CALL(cudaMallocHost(&adjk, edge_num * sizeof(vtx_t)));
      }

    }

    CUDA_RT_CALL(cudaMemcpy(xadj, ginst->xadj, (vtx_num + 1) * sizeof(edge_t),
                            cudaMemcpyDefault));
    CUDA_RT_CALL(cudaMemcpy(adjncy, ginst->adjncy, edge_num * sizeof(vtx_t),
                            cudaMemcpyDefault));
    if (FLAGS_weight || FLAGS_randomweight)
      CUDA_RT_CALL(cudaMemcpy(adjwgt, ginst->adjwgt,
                              edge_num * sizeof(weight_t), cudaMemcpyDefault));
    if (FLAGS_absorbphik) {
      CUDA_RT_CALL(cudaMemcpy(adjsrc, ginst->adjsrc, 
                              edge_num * sizeof(vtx_t), cudaMemcpyHostToDevice));
      CUDA_RT_CALL(cudaMemcpy(adjk, ginst->adjk, edge_num * sizeof(vtx_t), cudaMemcpyHostToDevice));
    }

    MaxDegree = ginst->MaxDegree;
    maxD = ginst->maxD;
    maxInD = ginst->maxInD;
    uint numZero = 0;
    for(size_t i = 0; i < ginst->numNode; i++) {
      ginst->outDegree[i] == 0 ? numZero++ : numZero = numZero;
    }
      printf("Nodes with degree zero: %d, ", numZero);
    printf("\n\n");
    if (FLAGS_umgraph) Set_Mem_Policy(FLAGS_weight || FLAGS_randomweight, FLAGS_absorbphik);
    // bias = static_cast<BiasType>(FLAGS_dw);
    // getBias= &gpu_graph::getBiasImpl;
    // (graph->*(graph->getBias))
  }
  void Set_Mem_Policy(bool needWeight = false, bool needAbsorb = false) {
    LOG("Set_Mem_Policy\n");
    // LOG("cudaMemAdvise %d %d\n", device_id, omp_get_thread_num());
    if (FLAGS_ab) {
      LOG("Policy ab\n");
      CUDA_RT_CALL(cudaMemAdvise(xadj, (vtx_num + 1) * sizeof(edge_t),
                                 cudaMemAdviseSetAccessedBy, device_id));
      CUDA_RT_CALL(cudaMemAdvise(adjncy, edge_num * sizeof(vtx_t),
                                 cudaMemAdviseSetAccessedBy, device_id));
      if (needWeight)
        CUDA_RT_CALL(cudaMemAdvise(adjwgt, edge_num * sizeof(weight_t),
                                   cudaMemAdviseSetAccessedBy, device_id));
      if (needAbsorb) {
        CUDA_RT_CALL(cudaMemAdvise(adjsrc, edge_num * sizeof(vtx_t),
                                   cudaMemAdviseSetAccessedBy, device_id));
        CUDA_RT_CALL(cudaMemAdvise(adjk, edge_num * sizeof(vtx_t),
                                   cudaMemAdviseSetAccessedBy, device_id));
      }
    }

    if (FLAGS_pf) {
      LOG("Policy pf\n");
      if ((edge_num + 1) * sizeof(edge_t) / 1024 / 1024 / 1024 >
          (needWeight ? 5 : 10)) {
        FLAGS_pfr = 0.5;
        LOG(" Overridding PF ratio to %f\n", (double)FLAGS_pfr);
      }
      CUDA_RT_CALL(cudaMemPrefetchAsync(
          xadj, (size_t)((vtx_num + 1) * sizeof(edge_t) * FLAGS_pfr), device_id,
          0));
      CUDA_RT_CALL(cudaMemPrefetchAsync(
          adjncy, (size_t)(edge_num * sizeof(vtx_t) * FLAGS_pfr), device_id,
          0));

      if (needWeight)
        CUDA_RT_CALL(cudaMemPrefetchAsync(
            adjwgt, (size_t)(edge_num * sizeof(weight_t) * FLAGS_pfr),
            device_id, 0));
      if (needAbsorb) {
        CUDA_RT_CALL(cudaMemPrefetchAsync(
            adjsrc, (size_t)(edge_num * sizeof(vtx_t) * FLAGS_pfr),
            device_id, 0));
        CUDA_RT_CALL(cudaMemPrefetchAsync(
            adjk, (size_t)(edge_num * sizeof(vtx_t) * FLAGS_pfr),
            device_id, 0));
      }


    } else {
      LOG("UM from host\n");
      CUDA_RT_CALL(cudaMemPrefetchAsync(xadj, (vtx_num + 1) * sizeof(edge_t),
                                        cudaCpuDeviceId, 0));
      CUDA_RT_CALL(cudaMemPrefetchAsync(adjncy, edge_num * sizeof(vtx_t),
                                        cudaCpuDeviceId, 0));

      if (needWeight)
        CUDA_RT_CALL(cudaMemPrefetchAsync(adjwgt, edge_num * sizeof(weight_t),
                                          cudaCpuDeviceId, 0));
      if (needAbsorb) {
        CUDA_RT_CALL(cudaMemPrefetchAsync(
            adjsrc, edge_num * sizeof(vtx_t),
            device_id, 0));
        CUDA_RT_CALL(cudaMemPrefetchAsync(
            adjk, edge_num * sizeof(vtx_t),
            device_id, 0));
      }
    }
    CUDA_RT_CALL(cudaDeviceSynchronize());
  }
  __host__ void Free() {
    if (!FLAGS_hmgraph) {
      LOG("free\n");
      if (xadj != nullptr) CUDA_RT_CALL(cudaFree(xadj));
      if (adjncy != nullptr) CUDA_RT_CALL(cudaFree(adjncy));
      if (adjwgt != nullptr && (FLAGS_weight || FLAGS_randomweight) && FLAGS_ol)
        CUDA_RT_CALL(cudaFree(adjwgt));
      if (adjsrc != nullptr && FLAGS_absorbphik) {
        CUDA_RT_CALL(cudaFree(adjsrc));
        CUDA_RT_CALL(cudaFree(adjk));
      }

    } else {
      if (xadj != nullptr) CUDA_RT_CALL(cudaFreeHost(xadj));
      if (adjncy != nullptr) CUDA_RT_CALL(cudaFreeHost(adjncy));
      if (adjwgt != nullptr && (FLAGS_weight || FLAGS_randomweight) && FLAGS_ol)
        CUDA_RT_CALL(cudaFreeHost(adjwgt));
      if (adjsrc != nullptr && FLAGS_absorbphik) {
        CUDA_RT_CALL(cudaFreeHost(adjsrc));
        CUDA_RT_CALL(cudaFreeHost(adjk));
      }
    }
  }

  __device__ edge_t getDegree(edge_t idx) {
#ifndef NDEBUG
    if (idx > vtx_num) {
      printf("getDegree out. %u %u\n", idx, vtx_num);
    }
#endif
    return xadj[idx + 1] - xadj[idx];
  }
  // __host__ edge_t getDegree_h(edge_t idx) { return outDegree[idx]; }
  // __device__ float getBias(edge_t id);
  __device__ float getBias(edge_t dst, uint src = 0, uint idx = 0);

  // degree 2 [0 ,1 ]
  // < 1 [1]
  // 1
  __device__ bool CheckValid(uint node_id) {
    return valid[node_id - local_vtx_offset];
  }
  __device__ void SetValid(uint node_id) {
    valid[node_id - local_vtx_offset] = 1;
  }
  // __device__ size_t GetVtxOffset(uint node_id) {
  //   return xadj[node_id - local_vtx_offset];
  // }

  __device__ uint BinarySearch(uint *ptr, uint size, int target) {
    uint tmp_size = size;
    uint *tmp_ptr = ptr;
    // printf("checking %d\t", target);
    uint itr = 0;
    while (itr < 50) {
      // printf("%u %u.\t",tmp_ptr[tmp_size / 2],target );
      if (tmp_ptr[tmp_size / 2] == target) {
        return tmp_size / 2;
      } else if (tmp_ptr[tmp_size / 2] < target) {
        tmp_ptr += tmp_size / 2;
        if (tmp_size == 1) {
          return 0;
        }
        tmp_size = tmp_size - tmp_size / 2;
      } else {
        tmp_size = tmp_size / 2;
      }
      if (tmp_size == 0) {
        return 0;
      }
      itr++;
    }
    return 0;
  }
  __device__ bool CheckConnect(int src, int dst) {
    // uint degree = getDegree(src);
    if (BinarySearch(adjncy + xadj[src], getDegree(src), dst)) {
      // paster()
      // printf("Connect %d %d \n", src, dst);
      return true;
    }
    // printf("not Connect %d %d \n", src, dst);
    return false;
  }
  __device__ float getBiasImpl(edge_t idx) { return xadj[idx + 1] - xadj[idx]; }
  __device__ edge_t getOutNode(edge_t idx, uint offset) {
    // uint offset = (unsigned long long)(adjncy + xadj[idx] + offset) / 4;
    // vtx_t *ptr =
    //     (vtx_t *)(((unsigned long long)(adjncy + xadj[idx] + offset + 8)) &
    //     -8);
    // int2 tmp = (reinterpret_cast<int2 *>((ptr))[0]);
    // return tmp.x;

    // vtx_t tmp;
    // for (size_t i = 0; i < 16; i++) {
    //   tmp += adjncy[xadj[idx] + offset + i];
    // }
    return adjncy[xadj[idx] + offset];
  }

  __device__ float getEdgeWeight(uint src, uint dst) {
    if(adjwgt == nullptr) {
      return 1.0;
    }
    uint offset = BinarySearch(adjncy + xadj[src], getDegree(src), dst);
    if (offset == 0) {
      return 1.0;
    }
    return adjwgt[xadj[src] + offset];
  }

  __host__ edge_t getEdgeNum() {
    return local_edge_num;
  }

  __device__ vtx_t *getNeighborPtr(edge_t idx) { return adjncy + xadj[idx]; }
  __device__ void UpdateWalkerState(uint idx, uint info);
};

struct AliasTable {
  float *prob_array = nullptr;
  uint *alias_array = nullptr;
  char *valid = nullptr;
  AliasTable() : prob_array(nullptr), alias_array(nullptr), valid(nullptr) {}
  void Free() {
    if (prob_array != nullptr) CUDA_RT_CALL(cudaFreeHost(prob_array));
    if (alias_array != nullptr) CUDA_RT_CALL(cudaFreeHost(alias_array));
    if (valid != nullptr) CUDA_RT_CALL(cudaFreeHost(valid));
    prob_array = nullptr;
    alias_array = nullptr;
    valid = nullptr;
  }
  void Alocate(size_t num_vtx, size_t num_edge) {
    AlocateHost(num_vtx, num_edge);
  }
  void AlocateHost(size_t num_vtx, size_t num_edge) {
    CUDA_RT_CALL(cudaHostAlloc((void **)&prob_array, num_edge * sizeof(float),
                               cudaHostAllocWriteCombined));
    CUDA_RT_CALL(cudaHostAlloc((void **)&alias_array, num_edge * sizeof(uint),
                               cudaHostAllocWriteCombined));
    CUDA_RT_CALL(cudaHostAlloc((void **)&valid, num_vtx * sizeof(char),
                               cudaHostAllocWriteCombined));
  }
  void Assemble(gpu_graph g) {
    CUDA_RT_CALL(cudaMemcpy((prob_array + g.local_edge_offset), g.prob_array,
                            g.local_edge_num * sizeof(float),
                            cudaMemcpyDefault));
    CUDA_RT_CALL(cudaMemcpy((alias_array + g.local_edge_offset), g.alias_array,
                            g.local_edge_num * sizeof(uint),
                            cudaMemcpyDefault));
    CUDA_RT_CALL(cudaMemcpy((valid + g.local_vtx_offset), g.valid,
                            g.local_vtx_num * sizeof(char), cudaMemcpyDefault));
  }
};

#endif

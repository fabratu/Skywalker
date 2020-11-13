#include "util.cuh"

#define SHMEM_SIZE 49152

#define BLOCK_SIZE 256
#define WARP_PER_SM (BLOCK_SIZE / 32)

#define SHMEM_PER_WARP (SHMEM_SIZE / WARP_PER_SM)

#define TMP_PER_ELE (4 + 4 + 4 + 4 + 2)
// #define TMP_PER_ELE (4 + 4 + 4 + 4 + 1)
// alignment
#define ELE_PER_WARP (SHMEM_PER_WARP / TMP_PER_ELE - 12) //8

template <typename T>
class Vector_itf
{
public:
  Vector_itf() {}
  ~Vector_itf() {}
  virtual void init() {}
  virtual void add() {}
  virtual void clean() {}
  virtual bool empty() {}
  virtual size_t size() {}
  virtual T &operator[](int id) {}
};

template <typename T>
struct buf
{
  T data[ELE_PER_WARP];
};

template <typename T>
struct Vector_shmem
{
  uint size = 0;
  uint capacity = ELE_PER_WARP;
  T data[ELE_PER_WARP];
  char *name;

  // __device__ void Init(size_t s = 0)
  // {
  //   if (LID == 0)
  //   {
  //     capacity = ELE_PER_WARP;
  //     size = s;
  //   }
  //   for (size_t i = LID; i < capacity; i += 32)
  //   {
  //     data[i] = 0;
  //   }
  // }
  __device__ void Init(char *_name, size_t s = 0)
  {
    if (LID == 0)
    {
      name = _name;
      // capacity = ELE_PER_WARP;
      size = s;
    }
    capacity = ELE_PER_WARP;
    for (size_t i = LID; i < capacity; i += 32)
    {
      data[i] = 0;
    }
  }
  __device__ volatile uint Size() { return size; }
  __device__ void Add(T t)
  {
    if (Size() < ELE_PER_WARP)
    {
      uint old = atomicAdd(&size, 1);
      if (old < capacity)
      {
        // if (old >= ELE_PER_WARP)
        //   printf("LINE: %d Add too large %u, size %u  capacity %u \n", __LINE__, old, size, capacity);
        data[old] = t;
      }
      else
      {
        atomicDec(&size, 1);
        // if (LID == 0)
        //   printf("Vector_shmem %s overflow %u\n", *name, old);
      }
    }
  }
  __device__ void Clean() { size = 0; }
  __device__ bool Empty()
  {
    if (size == 0)
      return true;
    return false;
  }
  __device__ T &operator[](int id) { return data[id]; }
};

// template <typename T> __global__ void myMemsetKernel(T *ptr, size_t size){
//   for (size_t i = TID; i < size; i+=BLOCK_SIZE)
//   {
//     ptr[i]=
//   }

// }

// template <typename T> void myMemset(T *ptr, size_t size){

// }

template <typename T>
class Vector
{
public:
  u64 *size;
  u64 *capacity;
  T *data = nullptr;
  bool use_self_buffer = false;
  // T data[VECTOR_SHMEM_SIZE];

  __host__ Vector() {}
  __host__ void free()
  {
    if (use_self_buffer && data != nullptr)
      cudaFree(data);
  }
  __device__ __host__ ~Vector() {}
  __host__ void init(int _capacity)
  {
    cudaMallocManaged(&size, sizeof(u64));
    cudaMallocManaged(&capacity, sizeof(u64));
    *capacity = _capacity;
    *size = 0;
    // init_array(capacity,1,_capacity);
    // init_array(capacity,1,_capacity);
    cudaMalloc(&data, _capacity * sizeof(T));
    use_self_buffer = true;
  }
  __host__ __device__ volatile u64 Size() { return *size; }
  __device__ void add(T t)
  {
    u64 old = atomicAdd(size, 1);
    if (old < *capacity)
      data[old] = t;
    else
      printf("vector overflow %d\n", old);
  }
  __device__ void AddTillSize(T t, u64 target_size)
  {
    u64 old = atomicAdd(size, 1);
    if (old < *capacity)
    {
      if (old < target_size)
        data[old] = t;
    }
    else
      printf("already full %d\n", old);
  }
  __device__ void clean() { *size = 0; }
  __device__ bool empty()
  {
    if (*size == 0)
      return true;
    return false;
  }
  __device__ T &operator[](int id) { return data[id]; }
};
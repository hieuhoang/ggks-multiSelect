/* Copyright 2011 Russel Steinbach, Jeffrey Blanchard, Bradley Gordon,
 *   and Toluwaloju Alabi
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *     
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <stdio.h>
#include <thrust/sort.h>

namespace BucketSelect{
  using namespace std;

#define MAX_THREADS_PER_BLOCK 1024
#define CUTOFF_POINT 200000 

#define CUDA_CALL(x) do { if((x) != cudaSuccess) {      \
      printf("Error at %s:%d\n",__FILE__,__LINE__);     \
      return EXIT_FAILURE;}} while(0)

  template<typename T>
  void cleanup(uint *h_c, T* d_k, int *etb, uint *bc){
    free(h_c);
    cudaFree(d_k);
    cudaFree(etb);
    cudaFree(bc);
  }

  //This function initializes a vector to all zeros on the host (CPU)
  void setToAllZero(uint* deviceVector, int length){
    cudaMemset(deviceVector, 0, length * sizeof(uint));
  }

  //this function assigns elements to buckets
  template <typename T>
  __global__ void assignBucket(T* d_vector, int length, int bucketNumbers, double slope, double minimum, int* bucket, uint* bucketCount, int offset){
  
    int idx = blockDim.x * blockIdx.x + threadIdx.x;
    int bucketIndex;
    extern __shared__ uint sharedBuckets[];
    int index = threadIdx.x;  
 
    //variables in shared memory for fast access
    __shared__ int sbucketNums;
    __shared__ double sMin;
    sbucketNums = bucketNumbers;
    sMin = minimum;

    //reading bucket counts into shared memory where increments will be performed
    if(index < bucketNumbers){
      sharedBuckets[index] = 0;
    }
    syncthreads();

    //assigning elements to buckets and incrementing the bucket counts
    if(idx < length)    {
      int i;
      for(i=idx; i< length; i+=offset){   
        //calculate the bucketIndex for each element
        bucketIndex =  (d_vector[i] - sMin) * slope;

        //if it goes beyond the number of buckets, put it in the last bucket
        if(bucketIndex >= sbucketNums){
          bucketIndex = sbucketNums - 1;
        }
        bucket[i] = bucketIndex;
        atomicInc(&sharedBuckets[bucketIndex], length);
      }
    }

    syncthreads();

    //reading bucket counts from shared memory back to global memory
    if(index < bucketNumbers){
      atomicAdd(&bucketCount[index], sharedBuckets[index]);
    }
  }

  //this function reassigns elements to buckets
  template <typename T>
  __global__ void reassignBucket(T* d_vector, int *bucket, uint *bucketCount, const int bucketNumbers, const int length, const double slope, const double maximum, const double minimum, int offset, int Kbucket){
    int idx = blockDim.x * blockIdx.x + threadIdx.x;
    extern __shared__ uint sharedBuckets[];
    int index = threadIdx.x;
    int bucketIndex;

    //reading bucket counts to shared memory where increments will be performed
    if(index < bucketNumbers){
      sharedBuckets[index] =0;
    }
    syncthreads();

    //assigning elements to buckets and incrementing the bucket counts
    if (idx < length){
      int i;

      for(i=idx; i<length; i+=offset){
        if(bucket[i] != Kbucket){
          bucket[i] = bucketNumbers+1;
        }
        else{
          //calculate the bucketIndex for each element
          bucketIndex = (d_vector[i] - minimum) * slope;

          //if it goes beyond the number of buckets, put it in the last bucket
          if(bucketIndex >= bucketNumbers){
            bucketIndex = bucketNumbers - 1;
          }
          bucket[i] = bucketIndex;

          atomicInc(&sharedBuckets[bucketIndex], length);
        }
      }
    }

    syncthreads();

    //reading bucket counts from shared memory back to global memory
    if(index < bucketNumbers){
      atomicAdd(&bucketCount[index], sharedBuckets[index]);
    }
  }

  //copy elements in the kth bucket to a new array
  template <typename T>
  __global__ void copyElement(T* d_vector, int length, int* elementArray, int bucket, T* newArray, uint* count, int offset){
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if(idx < length){
      int i;
      for(i=idx; i<length; i+=offset){
        //copy elements in the kth bucket to the new array
        if(elementArray[i] == bucket){
          newArray[atomicInc(&count[0],length)] = d_vector[i];
        }
      }
    }
  }

  //this function finds the bin containing the kth element we are looking for (works on the host)
  inline int FindKBucket(uint *d_counter, uint *h_counter, const int num_buckets, const int k, uint * sum){
    cudaMemcpy(sum, d_counter, sizeof(uint), cudaMemcpyDeviceToHost);
    int Kbucket = 0;
    
    if (sum[0]<k){
      cudaMemcpy(h_counter, d_counter, num_buckets * sizeof(uint), cudaMemcpyDeviceToHost);
      while ( (sum[0]<k) & (Kbucket<num_buckets-1)){
        Kbucket++; 
        sum[0] = sum[0] + h_counter[Kbucket];
      }
    }
    else{
      cudaMemcpy(h_counter, d_counter, sizeof(uint), cudaMemcpyDeviceToHost);
    }
  
    return Kbucket;
  }

  template <typename T>
  __global__ void GetKvalue(T* d_vector, int * d_bucket, const int Kbucket, const int n, T* Kvalue, int offset )
  {
    uint xIndex = blockDim.x * blockIdx.x + threadIdx.x;

    if (xIndex < n) {
      int i;
      for(i=xIndex; i<n; i+=offset){
        if ( d_bucket[i] == Kbucket ) {
          Kvalue[0] = d_vector[i];
        }
      }
    }
  }


  /************************************************************************/
  /************************************************************************/
  //THIS IS THE PHASE TWO FUNCTION WHICH WILL BE CALLED IF THE INPUT
  //LENGTH IS LESS THAN THE CUTOFF OF 2MILLION 200 THOUSAND
  /************************************************************************/


  template <typename T>
  T phaseTwo(T* d_vector, int length, int K, int blocks, int threads, double maxValue = 0, double minValue = 0){ 
    //declaring and initializing variables for kernel launches
    int threadsPerBlock = threads;
    int numBlocks = blocks;
    int numBuckets = 1024;
    int offset = blocks * threads;

    uint sum=0, Kbucket=0, iter=0;
    int Kbucket_count = 0;
 
    //initializing variables for kernel launches
    if(length < 1024){
      numBlocks = 1;
    }
    //variable to store the end result
    T kthValue =0;

    //declaring and initializing other variables
    size_t size = length * sizeof(int);
    size_t totalBucketSize = numBuckets * sizeof(uint);

    //allocate memory to store bucket assignments and to count elements in buckets
    int* elementToBucket;
    uint* d_bucketCount;
    cudaMalloc(&elementToBucket, size);
    cudaMalloc(&d_bucketCount, totalBucketSize);
    uint * h_bucketCount = (uint*)malloc(totalBucketSize);

    T* d_Kth_val;
    cudaMalloc(&d_Kth_val, sizeof(T));

    thrust::device_ptr<T>dev_ptr(d_vector);
    //if max == min, then we know that it must not have had the values passed in. 
    if(maxValue == minValue){
      thrust::pair<thrust::device_ptr<T>, thrust::device_ptr<T> > result = thrust::minmax_element(dev_ptr, dev_ptr + length);
      minValue = *result.first;
      maxValue = *result.second;
    }
    double slope = (numBuckets - 1)/(maxValue - minValue);
    //first check is max is equal to min
    if(maxValue == minValue){
      cleanup(h_bucketCount, d_Kth_val, elementToBucket,d_bucketCount);
      return maxValue;
    }

    //make all entries of this vector equal to zero
    setToAllZero(d_bucketCount, numBuckets);
    //distribute elements to bucket
    assignBucket<<<numBlocks, threadsPerBlock, numBuckets*sizeof(uint)>>>(d_vector, length, numBuckets, slope, minValue, elementToBucket, d_bucketCount, offset);

    //find the bucket containing the kth element we want
    Kbucket = FindKBucket(d_bucketCount, h_bucketCount, numBuckets, K, &sum);
    Kbucket_count = h_bucketCount[Kbucket];

    while ( (Kbucket_count > 1) && (iter < 1000)){
      minValue = max(minValue, minValue + Kbucket/slope);
      maxValue = min(maxValue, minValue + 1/slope);

      K = K - sum + Kbucket_count;

      if ( maxValue - minValue > 0.0f ){
        slope = (numBuckets - 1)/(maxValue-minValue);
        setToAllZero(d_bucketCount, numBuckets);
        reassignBucket<<< numBlocks, threadsPerBlock, numBuckets * sizeof(uint) >>>(d_vector, elementToBucket, d_bucketCount, numBuckets,length, slope, maxValue, minValue, offset, Kbucket);

        sum = 0;
        Kbucket = FindKBucket(d_bucketCount, h_bucketCount, numBuckets, K, &sum);
        Kbucket_count = h_bucketCount[Kbucket];

        iter++;
      }
      else{
        //if the max and min are the same, then we are done
        cleanup(h_bucketCount, d_Kth_val, elementToBucket, d_bucketCount);
        return maxValue;
      }
    }

    GetKvalue<<<numBlocks, threadsPerBlock >>>(d_vector, elementToBucket, Kbucket, length, d_Kth_val, offset);
    cudaMemcpy(&kthValue, d_Kth_val, sizeof(T), cudaMemcpyDeviceToHost);
    cudaThreadSynchronize();
  

    cleanup(h_bucketCount, d_Kth_val, elementToBucket, d_bucketCount);
    return kthValue;
  }



  /* this function finds the kth-largest element from the input array */
  template <typename T>
  T phaseOne(T* d_vector, int length, int K, int blocks, int threads, int pass = 0){
    //declaring variables for kernel launches
    int threadsPerBlock = threads;
    int numBlocks = blocks;
    int numBuckets = 1024;
    int offset = blocks * threads;
    int kthBucket, kthBucketCount;
    int newInputLength;
    int* elementToBucket; //array showing what bucket every element is in
    //declaring and initializing other variables

    uint *d_bucketCount, *count; //array showing the number of elements in each bucket
    uint kthBucketScanSize = 0;

    size_t size = length * sizeof(int);

    //variable to store the end result
    T kthValue = 0;
    T* newInput;

    //find max and min with thrust
    double maximum, minimum;

    thrust::device_ptr<T>dev_ptr(d_vector);
    thrust::pair<thrust::device_ptr<T>, thrust::device_ptr<T> > result = thrust::minmax_element(dev_ptr, dev_ptr + length);

    minimum = *result.first;
    maximum = *result.second;

    //if the max and the min are the same, then we are done
    if(maximum == minimum){
      return maximum;
    }
    //if we want the max or min just return it
    if(K == 1){
      return minimum;
    }
    if(K == length){
      return maximum;
    }		
    //Allocate memory to store bucket assignments
  
    CUDA_CALL(cudaMalloc(&elementToBucket, size));

    //Allocate memory to store bucket counts
    size_t totalBucketSize = numBuckets * sizeof(uint);
    CUDA_CALL(cudaMalloc(&d_bucketCount, totalBucketSize));
    uint* h_bucketCount = (uint*)malloc(totalBucketSize);

    //Calculate max-min
    double range = maximum - minimum;
    //Calculate the slope, i.e numBuckets/range
    double slope = (numBuckets - 1)/range;

    cudaMalloc(&count, sizeof(uint));
    //Set the bucket count vector to all zeros
    setToAllZero(d_bucketCount, numBuckets);

    //Distribute elements into their respective buckets
    assignBucket<<<numBlocks, threadsPerBlock, numBuckets*sizeof(uint)>>>(d_vector, length, numBuckets, slope, minimum, elementToBucket, d_bucketCount, offset);
    
    kthBucket = FindKBucket(d_bucketCount, h_bucketCount, numBuckets, K, & kthBucketScanSize);
    kthBucketCount = h_bucketCount[kthBucket];
 

    //we must update K since we have reduced the problem size to elements in the kth bucket
    if(kthBucket != 0){
      K = kthBucketCount - (kthBucketScanSize - K);
    }

    //copy elements in the kth bucket to a new array
    cudaMalloc(&newInput, kthBucketCount * sizeof(T));
    setToAllZero(count, 1);
    copyElement<<<numBlocks, threadsPerBlock>>>(d_vector, length, elementToBucket, kthBucket, newInput, count, offset);


    //store the length of the newly copied elements
    newInputLength = kthBucketCount;


    //if we only copied one element, then we are done
    if(newInputLength == 1){
      thrust::device_ptr<T>new_ptr(newInput);
      kthValue = new_ptr[0];
      
      //free all used memory
      cudaFree(elementToBucket); cudaFree(d_bucketCount); cudaFree(count); cudaFree(newInput);
      return kthValue;
    }
 
    /*********************************************************************/
    //END OF FIRST PASS, NOW WE PROCEED TO SUBSEQUENT PASSES
    /*********************************************************************/

    //if the new length is greater than the CUTOFF, run the regular phaseOne again
    if(newInputLength > CUTOFF_POINT && pass < 1){
      if(pass > 0){
        cudaFree(d_vector);
      }
      cudaFree(elementToBucket);  cudaFree(d_bucketCount); cudaFree(count);
      kthValue = phaseOne(newInput, newInputLength, K, blocks, threads,pass + 1);
    }
    else{
      minimum = max(minimum, minimum + kthBucket/slope);
      maximum = min(maximum, minimum + 1/slope);
      kthValue = phaseTwo(newInput,newInputLength, K, blocks, threads,maximum, minimum);
    }


    //free all used memory
    cudaFree(elementToBucket);  cudaFree(d_bucketCount); cudaFree(newInput); cudaFree(count);

    return kthValue;
  }

  
  /************************* BEGIN FUNCTIONS FOR RANDOMIZEDBUCKETSELECT ************************/
  /************************* BEGIN FUNCTIONS FOR RANDOMIZEDBUCKETSELECT ************************/
  /************************* BEGIN FUNCTIONS FOR RANDOMIZEDBUCKETSELECT ************************/

  void createRandomMatrix(float * d_A, int size, int seed) {
    curandGenerator_t gen;

    curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
    curandSetPseudoRandomGeneratorSeed(gen, seed);

    curandGenerateUniform(gen, d_A, size);

    curandDestroyGenerator(gen);
  }

  __global__ void enlargeIndexAndGetElements (float * in, float * list, int size) {
    *(in + threadIdx.x) = *(list + ((int) (*(in + threadIdx.x) * size)));
  }

  template <typename T>
  void generatePivots (T * pivots, double * slopes, T * d_list, int numElements, int numPivots, int sampleSize, T min, T max) {

    T * d_randoms;
  
    cudaMalloc ((void **) &d_randoms, sizeof (T) * sampleSize);
  
    createRandomMatrix (d_randoms, sampleSize, 1);

    // turn randoms floats into necessary indices
    enlargeIndexAndGetElements<<<1, sampleSize>>>(d_randoms, d_list, numElements);

    pivots[0] = min; 
    pivots[numPivots-1] = max;

    thrust::device_ptr<T>randoms_ptr(d_randoms);
    thrust::sort(randoms_ptr, randoms_ptr + sampleSize);

    cudaThreadSynchronize();

    for (int i = 1; i < numPivots - 1; i++) {
      cudaMemcpy (pivots + i, d_randoms +(sampleSize / (numPivots - 1) * i), sizeof (T), cudaMemcpyDeviceToHost);
      slopes[i-1] = (pivots[i] - pivots[i-1]) / (sampleSize / (numPivots - 1));
    }
    
    slopes[numPivots-2] = (pivots[numPivots-1] - pivots[numPivots-2]) / (sampleSize / (numPivots - 1));
  
    cudaFree(d_randoms);
  }
  
 //this function assigns elements to buckets based off of a randomized sampling of the elements in the vector
  template <typename T>
  __global__ void assignSmartBucket(T * d_vector, int length, int bucketNumbers, double * slopes, T * pivots, int numPivots, int* bucket, uint* bucketCount, int offset){
  
    int idx = blockDim.x * blockIdx.x + threadIdx.x;
    int bucketIndex;
    extern __shared__ uint sharedBuckets[];
    int index = threadIdx.x;  
 
    //variables in shared memory for fast access
    __shared__ int sbucketNums;
    // __shared__ double sMin;
    sbucketNums = bucketNumbers;
    //sMin = pivots[numPivots - 1];

    //reading bucket counts into shared memory where increments will be performed
    if(index < bucketNumbers){
      sharedBuckets[index] = 0;
    }
    syncthreads();

    //assigning elements to buckets and incrementing the bucket counts
    if(idx < length)    {
      int i;

      for(i = idx; i < length; i += offset){
        T num = d_vector[i];
        int minPivotIndex = 0;
        int maxPivotIndex = numPivots-1;
        int midPivotIndex;

        // find the index of the pivot that is the greatest s.t. lower than or equal to num
        while (maxPivotIndex >= minPivotIndex) {
          midPivotIndex = (maxPivotIndex + minPivotIndex) / 2;

          if (pivots[midPivotIndex+1] <= num)
            minPivotIndex = midPivotIndex+1;
          else if (pivots[midPivotIndex] > num)
            maxPivotIndex = midPivotIndex;
          else
            break;
        }
        
        bucketIndex = (midPivotIndex * (sbucketNums/numPivots-1)) + ((num - pivots[midPivotIndex]) / slopes[midPivotIndex]);
        

        /*
        //calculate the bucketIndex for each element
        bucketIndex =  (d_vector[i] - sMin) * slope;
        //if it goes beyond the number of buckets, put it in the last bucket
        if(bucketIndex >= sbucketNums){
          bucketIndex = sbucketNums - 1;
          }
        */
        bucket[i] = bucketIndex;
        atomicInc(&sharedBuckets[bucketIndex], length);
      }
    }

    syncthreads();

    //reading bucket counts from shared memory back to global memory
    if(index < bucketNumbers){
      atomicAdd(&bucketCount[index], sharedBuckets[index]);
    }
  }

  /* this function finds the kth-largest element from the input array */
  template <typename T>
  T phaseOneR(T* d_vector, int length, int K, int blocks, int threads, int pass = 0){
    //declaring variables for kernel launches
    int threadsPerBlock = threads;
    int numBlocks = blocks;
    int numBuckets = 1024;
    int offset = blocks * threads;
    int kthBucket, kthBucketCount;
    int newInputLength;

    int* d_elementToBucket; //array showing what bucket every element is in
    //Allocate memory to store bucket assignments  
    CUDA_CALL(cudaMalloc(&d_elementToBucket, size));


    //declaring and initializing other variables

    int numPivots = 9;
    int sampleSize = 1024;
    
    uint *d_bucketCount, *count; //array showing the number of elements in each bucket
    uint kthBucketScanSize = 0;

    size_t size = length * sizeof(int);

    //variable to store the end result
    T kthValue = 0;
    T* newInput;

    //find max and min with thrust
    T maximum, minimum;

    thrust::device_ptr<T>dev_ptr(d_vector);
    thrust::pair<thrust::device_ptr<T>, thrust::device_ptr<T> > result = thrust::minmax_element(dev_ptr, dev_ptr + length);

    minimum = *result.first;
    maximum = *result.second;

    //if the max and the min are the same, then we are done
    if(maximum == minimum){
      return maximum;
    }
    //if we want the max or min just return it
    if(K == 1){
      return minimum;
    }
    if(K == length){
      return maximum;
    }		

    //Allocate memory to store bucket assignments  
    CUDA_CALL(cudaMalloc(&d_elementToBucket, size));

    //Allocate memory to store bucket counts
    size_t totalBucketSize = numBuckets * sizeof(uint);
    CUDA_CALL(cudaMalloc(&d_bucketCount, totalBucketSize));
    uint* h_bucketCount = (uint*)malloc(totalBucketSize);

    //Declare slopes and pivots
    double slopes[numPivots - 1];
    T pivots[numPivots];
    
    //Find bucket sizes using a randomized selection
    generatePivots<T>(pivots, slopes, d_vector, length, numPivots, sampleSize, minimum, maximum);
    printf("after genpivots\n");
    
    //Allocate memories
    double * d_slopes;
    CUDA_CALL(cudaMalloc(&d_slopes, (numPivots - 1) * sizeof(double)));
    cudaMemcpy(d_slopes, slopes, (numPivots - 1) * sizeof(double), cudaMemcpyHostToDevice);
    T * d_pivots;
    CUDA_CALL(cudaMalloc(&d_pivots, numPivots * sizeof(T)));
    cudaMemcpy(d_slopes, slopes, numPivots * sizeof(T), cudaMemcpyHostToDevice);

    CUDA_CALL(cudaMalloc(&count, sizeof(uint)));
    //Set the bucket count vector to all zeros
    setToAllZero(d_bucketCount, numBuckets);

    //Distribute elements into their respective buckets
    assignSmartBucket<<<numBlocks, threadsPerBlock, numBuckets*sizeof(uint)>>>(d_vector, length, numBuckets, d_slopes, d_pivots, numPivots, d_elementToBucket, d_bucketCount, offset);
    kthBucket = FindKBucket(d_bucketCount, h_bucketCount, numBuckets, K, & kthBucketScanSize);
    kthBucketCount = h_bucketCount[kthBucket];
 
    printf("after assignSmartBucket\n");
    //we must update K since we have reduced the problem size to elements in the kth bucket
    if(kthBucket != 0){
      K = kthBucketCount - (kthBucketScanSize - K);
    }

    //copy elements in the kth bucket to a new array
    cudaMalloc(&newInput, kthBucketCount * sizeof(T));
    setToAllZero(count, 1);
    copyElement<<<numBlocks, threadsPerBlock>>>(d_vector, length, d_elementToBucket, kthBucket, newInput, count, offset);


    //store the length of the newly copied elements
    newInputLength = kthBucketCount;


    //if we only copied one element, then we are done
    if(newInputLength == 1){
      thrust::device_ptr<T>new_ptr(newInput);
      kthValue = new_ptr[0];
      
      //free all used memory
      cudaFree(elementToBucket); cudaFree(d_bucketCount); cudaFree(count); cudaFree(newInput); cudaFree(d_slopes); cudaFree(d_pivots);
      return kthValue;
    }
 
    /*********************************************************************/
    //END OF FIRST PASS, NOW WE PROCEED TO SUBSEQUENT PASSES
    /*********************************************************************/

    //if the new length is greater than the CUTOFF, run the regular phaseOne again
    if(newInputLength > CUTOFF_POINT && pass < 1){
      if(pass > 0){
        cudaFree(d_vector);
      }
      cudaFree(elementToBucket);  cudaFree(d_bucketCount); cudaFree(count);
      kthValue = phaseOne(newInput, newInputLength, K, blocks, threads,pass + 1);
    }
    else{
      // find boundaries of kth bucket
      int pivotOffset = numBuckets / (numPivots - 1);
      int pivotIndex = kthBucket/pivotOffset;
      int pivotInnerindex = kthBucket - pivotOffset * pivotIndex;
      minimum = max(minimum, pivots[pivotIndex] + slopes[pivotIndex] * pivotInnerindex); 
      maximum = min(maximum, pivots[pivotIndex] + slopes[pivotIndex] * (pivotInnerindex+1));

      printf("kthBucket = %d\n", kthBucket);
      
      kthValue = phaseTwo(newInput,newInputLength, K, blocks, threads,maximum, minimum);
      
      /*
      minimum = max(minimum, minimum + kthBucket/slope);
      maximum = min(maximum, minimum + 1/slope);
      kthValue = phaseTwo(newInput,newInputLength, K, blocks, threads,maximum, minimum);
      */
    }


    //free all used memory
    cudaFree(elementToBucket);  cudaFree(d_bucketCount); cudaFree(newInput); cudaFree(count);


    printf("end of phase1, k = %f\n", kthValue);
    return kthValue;
  }

  /**************************************************************************/
  /**************************************************************************/
  //THIS IS THE BUCKETSELECT FUNCTION WRAPPER THAT CHOOSES THE CORRECT VERSION
  //OF BUCKET SELECT TO RUN BASED ON THE INPUT LENGTH
  /**************************************************************************/
  template <typename T>
  T bucketSelectWrapper(T* d_vector, int length, int K, int blocks, int threads)
  {
    T kthValue;
    //change K to be the kth smallest
    K = length - K + 1;

    if(length <= CUTOFF_POINT)
      {
        kthValue = phaseTwo(d_vector, length, K, blocks, threads);
        return kthValue;
      }
    else
      {
        kthValue = phaseOne(d_vector, length, K, blocks, threads);
        printf("After Call PhaseOne in bucket, kthvalue = %f.\n", kthValue);
        return kthValue;
      }

  }


  /**************************************************************************/
  /**************************************************************************/
  //THIS IS THE RANDOMIZEDBUCKETSELECT FUNCTION WRAPPER THAT CHOOSES THE CORRECT
  //VERSION OF BUCKET SELECT TO RUN BASED ON THE INPUT LENGTH
  /**************************************************************************/
  template <typename T>
  T randomizedBucketSelectWrapper(T* d_vector, int length, int K, int blocks, int threads)
  {
    T kthValue;
    //change K to be the kth smallest
    K = length - K + 1;

    if(length <= CUTOFF_POINT)
      {
        kthValue = phaseTwo(d_vector, length, K, blocks, threads);
        return kthValue;
      }
    else
      {
        printf("Call PhaseOneR in parent function.\n");
        kthValue = phaseOneR(d_vector, length, K, blocks, threads);
        printf("After Call PhaseOneR in parent function, kthvalue = %f.\n", kthValue);
        return kthValue;
      }

  }
}

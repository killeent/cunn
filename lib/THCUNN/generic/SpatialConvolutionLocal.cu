#ifndef THC_GENERIC_FILE
#define THC_GENERIC_FILE "generic/SpatialConvolutionLocal.cu"
#else

static inline void THNN_(SpatialConvolutionLocal_shapeCheck)(
                         THCState *state,
                         THCTensor *input, THCTensor *gradOutput,
                         THCTensor *weight, THCTensor *bias,
                         int kH, int kW, int dH,
                         int dW, int padH, int padW,
                         long inputHeight, long inputWidth,
                         long outputHeight, long outputWidth) {

  THArgCheck(kW > 0 && kH > 0, 9,
             "kernel size should be greater than zero, but got kH: %d kW: %d", kH, kW);
  THArgCheck(dW > 0 && dH > 0, 11,
             "stride should be greater than zero, but got dH: %d dW: %d", dH, dW);

  int ndim = input->nDimension;
  int dimf = 0;
  int dimh = 1;
  int dimw = 2;

  if (ndim == 4) {
    dimf++;
    dimh++;
    dimw++;
  }

  THCUNN_argCheck(state, ndim == 3 || ndim == 4, 2, input,
                  "3D or 4D input tensor expected but got: %s");

  long nInputPlane = weight->size[2] / (kH * kW);
  long nOutputPlane = weight->size[1];

  if (bias != NULL) {
   THCUNN_check_dim_size(state, bias, 3, 0, nOutputPlane);
   THCUNN_check_dim_size(state, bias, 3, 1, outputHeight);
   THCUNN_check_dim_size(state, bias, 3, 2, outputWidth);
  }

  THCUNN_check_dim_size(state, input, ndim, dimf, nInputPlane);

  if (gradOutput != NULL) {
    THCUNN_check_dim_size(state, gradOutput, ndim, dimf, nOutputPlane);
    THCUNN_check_dim_size(state, gradOutput, ndim, dimh, outputHeight);
    THCUNN_check_dim_size(state, gradOutput, ndim, dimw, outputWidth);
  }
}

static int THNN_(view_weight_local)(
                 THCState *state,
                 THCTensor **_weight)
{
  THCTensor *weight = *_weight;
  THArgCheck(weight->nDimension == 3 || weight->nDimension == 6, 4,
            "weight tensor should be 3D or 6D - got %dD", weight->nDimension);
  if (weight->nDimension == 6) {
    long s1 = weight->size[0] * weight->size[1];
    long s2 = weight->size[2];
    long s3 = weight->size[3] * weight->size[4] * weight->size[5];
    *_weight = THCTensor_(newWithStorage3d)(state,
                          weight->storage,
                          weight->storageOffset,
                          s1, -1, s2, -1, s3, -1);
    return 1;
  }
  return 0;
}

void THNN_(SpatialConvolutionLocal_updateOutput)(
           THCState *state,
           THCTensor *input,
           THCTensor *output,
           THCTensor *weight,
           THCTensor *bias,
           THCTensor *finput,
           THCTensor *fgradInput,
           int kW, int kH,
           int dW, int dH,
           int padW, int padH,
           long inputWidth, long inputHeight,
           long outputWidth, long outputHeight)
{
  THCUNN_assertSameGPU(state, 5, input, output, weight,
                       bias, finput);

  int freeWeight = THNN_(view_weight_local)(state, &weight);

  THNN_(SpatialConvolutionLocal_shapeCheck)
       (state, input, NULL, weight, bias, kH, kW, dH, dW, padH, padW,
        inputHeight, inputWidth, outputHeight, outputWidth);

  input = THCTensor_(newContiguous)(state, input);

  long nInputPlane = THCTensor_(size)(state,weight,2)/(kW*kH);
  long nOutputPlane = THCTensor_(size)(state,weight,1);

  int batch = 1;
  if (input->nDimension == 3) {
    // Force batch
    batch = 0;
    THCTensor_(resize4d)(state, input, 1, nInputPlane, inputHeight, inputWidth);
  }

  // Batch size + input planes
  long batchSize = input->size[0];

  // Resize output
  THCTensor_(resize4d)(state, output, batchSize, nOutputPlane, outputHeight, outputWidth);

  // Augment the input
  THCTensor_(resize3d)(state, finput, batchSize, nInputPlane*kW*kH, outputHeight*outputWidth);

  // Helpers
  THCTensor *input_n = THCTensor_(new)(state);
  THCTensor *finput_n = THCTensor_(new)(state);
  THCTensor *output_n = THCTensor_(new)(state);

  // For each elt in batch, do:
  for (int elt = 0; elt < batchSize; elt ++) {
    THCTensor *finput3d, *output3d;
    THCTensor *wslice = THCTensor_(new)(state);
    THCTensor *islice = THCTensor_(new)(state);
    THCTensor *oslice = THCTensor_(new)(state);

    // Matrix mulitply per output:
    THCTensor_(select)(state, input_n, input, 0, elt);
    THCTensor_(select)(state, finput_n, finput, 0, elt);
    THCTensor_(select)(state, output_n, output, 0, elt);

    // Extract columns:
    im2col(
      THCState_getCurrentStream(state),
      THCTensor_(data)(state, input_n),
      nInputPlane, inputHeight, inputWidth, kH, kW, padH, padW, dH, dW,
      1, 1, THCTensor_(data)(state, finput_n)
    );

    output3d = THCTensor_(newWithStorage3d)(state, output_n->storage, output_n->storageOffset,
                                             outputHeight*outputWidth, 1,
                                             nOutputPlane, outputHeight*outputWidth,
                                             1, nOutputPlane*outputHeight*outputWidth);

    finput3d = THCTensor_(newWithStorage3d)(state, finput_n->storage, finput_n->storageOffset,
                                             outputHeight*outputWidth, 1,
                                             kW*kH*nInputPlane, outputHeight*outputWidth,
                                             1, kW*kH*nInputPlane*outputHeight*outputWidth);

    THCTensor_(copy)(state, output_n, bias);

    for (int i = 0; i < outputHeight; i++) {
      for(int j = 0; j < outputWidth; j++) {
        int sliceidx = i * outputWidth + j;
        THCTensor_(select)(state, wslice, weight, 0, sliceidx);
        THCTensor_(select)(state, islice, finput3d, 0, sliceidx);
        THCTensor_(select)(state, oslice, output3d, 0, sliceidx);
        THCTensor_(addmm)(state, oslice, ScalarConvert<int, real>::to(1), oslice, ScalarConvert<int, real>::to(1), wslice, islice);
      }
    }


    // weight:    oH*oW x nOutputPlane x nInputPlane*kH*kW
    // finput3d:  oH*oW x nInputPlane*kH*kW x 1
    // THCTensor_(baddbmm)(state, output3d, 1.0, output3d, 1.0, weight, finput3d);
    // output3d:  oH*oW x nOutputPlane x 1

    THCTensor_(free)(state, output3d);
    THCTensor_(free)(state, finput3d);
    THCTensor_(free)(state, wslice);
    THCTensor_(free)(state, islice);
    THCTensor_(free)(state, oslice);
  }

  // Free
  THCTensor_(free)(state, input_n);
  THCTensor_(free)(state, finput_n);
  THCTensor_(free)(state, output_n);

  // Resize output
  if (batch == 0) {
    THCTensor_(resize3d)(state, output, nOutputPlane, outputHeight, outputWidth);
    THCTensor_(resize3d)(state, input, nInputPlane, inputHeight, inputWidth);
  }

  THCTensor_(free)(state, input);
  if (freeWeight)
     THCTensor_(free)(state, weight);
}

void THNN_(SpatialConvolutionLocal_updateGradInput)(
           THCState *state,
           THCTensor *input,
           THCTensor *gradOutput,
           THCTensor *gradInput,
           THCTensor *weight,
           THCTensor *finput,
           THCTensor *fgradInput,
           int kW, int kH,
           int dW, int dH,
           int padW, int padH,
           long inputWidth, long inputHeight,
           long outputWidth, long outputHeight)
{
  THCUNN_assertSameGPU(state, 5, input, gradOutput, weight,
                       fgradInput, gradInput);

  int freeWeight = THNN_(view_weight_local)(state, &weight);

  THNN_(SpatialConvolutionLocal_shapeCheck)
       (state, input, gradOutput, weight, NULL, kH, kW, dH, dW, padH, padW,
        inputHeight, inputWidth, outputHeight, outputWidth);

  input = THCTensor_(newContiguous)(state, input);

  long nInputPlane = THCTensor_(size)(state,weight,2)/(kW*kH);
  long nOutputPlane = THCTensor_(size)(state,weight,1);

  int batch = 1;
  if (input->nDimension == 3) {
    // Force batch
    batch = 0;
    THCTensor_(resize4d)(state, input, 1, nInputPlane, inputHeight, inputWidth);
    THCTensor_(resize4d)(state, gradOutput, 1, nOutputPlane, outputHeight, outputWidth);
  }

  // Batch size + input planes
  long batchSize = input->size[0];

  // Resize output
  THCTensor_(resize4d)(state, gradInput, batchSize, nInputPlane, inputHeight, inputWidth);

  // Resize temporary columns
  THCTensor_(resize3d)(state, fgradInput, batchSize, nInputPlane*kW*kH, outputHeight*outputWidth);

  // Helpers
  THCTensor *gradInput_n = THCTensor_(new)(state);
  THCTensor *fgradInput_n = THCTensor_(new)(state);
  THCTensor *gradOutput_n = THCTensor_(new)(state);

  THCTensor_(transpose)(state, weight, weight, 1, 2);

  // For each elt in batch, do:
  for (int elt = 0; elt < batchSize; elt ++) {
    THCTensor *gradOutput3d, *fgradInput3d;
    THCTensor *wslice = THCTensor_(new)(state);
    THCTensor *gislice = THCTensor_(new)(state);
    THCTensor *goslice = THCTensor_(new)(state);

    // Matrix mulitply per sample:
    THCTensor_(select)(state, gradInput_n, gradInput, 0, elt);
    THCTensor_(select)(state, fgradInput_n, fgradInput, 0, elt);
    THCTensor_(select)(state, gradOutput_n, gradOutput, 0, elt);

    gradOutput3d = THCTensor_(newWithStorage3d)(state, gradOutput_n->storage, gradOutput_n->storageOffset,
                                               outputHeight*outputWidth, 1,
                                               nOutputPlane, outputHeight*outputWidth,
                                               1, nOutputPlane*outputHeight*outputWidth);
    fgradInput3d = THCTensor_(newWithStorage3d)(state, fgradInput_n->storage, fgradInput_n->storageOffset,
                                               outputHeight*outputWidth, 1,
                                               kW*kH*nInputPlane, outputHeight*outputWidth,
                                               1, kW*kH*nInputPlane*outputHeight*outputWidth);

    for (int i = 0; i < outputHeight; i++) {
      for(int j = 0; j < outputWidth; j++) {
        int sliceidx = i * outputWidth + j;
        THCTensor_(select)(state, wslice, weight, 0, sliceidx);
        THCTensor_(select)(state, gislice, fgradInput3d, 0, sliceidx);
        THCTensor_(select)(state, goslice, gradOutput3d, 0, sliceidx);
        THCTensor_(addmm)(state, gislice, ScalarConvert<int, real>::to(0), gislice, ScalarConvert<int, real>::to(1), wslice, goslice);
      }
    }

    // weight:        oH*oW x nInputPlane*kH*kW x nOutputPlane
    // gradOutput3d:  oH*oW x nOutputPlane x 1
    //THCTensor_(baddbmm)(state, fgradInput3d, 0.0, fgradInput3d, 1.0, weight, gradOutput3d);
    // fgradInput3d:  oH*oW x nInputPlane*kH*kW x 1

    // Unpack columns back into input:
    col2im<real, accreal>(
      THCState_getCurrentStream(state),
      THCTensor_(data)(state, fgradInput_n),
      nInputPlane, inputHeight, inputWidth, kH, kW, padH, padW, dH, dW,
      1, 1, THCTensor_(data)(state, gradInput_n)
    );

    THCTensor_(free)(state, gradOutput3d);
    THCTensor_(free)(state, fgradInput3d);
    THCTensor_(free)(state, wslice);
    THCTensor_(free)(state, gislice);
    THCTensor_(free)(state, goslice);
  }

  // Free
  THCTensor_(free)(state, gradInput_n);
  THCTensor_(free)(state, fgradInput_n);
  THCTensor_(free)(state, gradOutput_n);

  // Resize output
  if (batch == 0) {
    THCTensor_(resize3d)(state, gradOutput, nOutputPlane, outputHeight, outputWidth);
    THCTensor_(resize3d)(state, input, nInputPlane, inputHeight, inputWidth);
    THCTensor_(resize3d)(state, gradInput, nInputPlane, inputHeight, inputWidth);
  }

  THCTensor_(transpose)(state, weight, weight, 1, 2);

  THCTensor_(free)(state, input);
  if (freeWeight)
     THCTensor_(free)(state, weight);
}

void THNN_(SpatialConvolutionLocal_accGradParameters)(
           THCState *state,
           THCTensor *input,
           THCTensor *gradOutput,
           THCTensor *gradWeight,
           THCTensor *gradBias,
           THCTensor *finput,
           THCTensor *fgradInput,
           int kW, int kH,
           int dW, int dH,
           int padW, int padH,
           long inputWidth, long inputHeight,
           long outputWidth, long outputHeight,
           real scale)
{
  THCUNN_assertSameGPU(state, 5, input, gradOutput, gradWeight,
                       gradBias, finput);

  int freeWeight = THNN_(view_weight_local)(state, &gradWeight);

  THNN_(SpatialConvolutionLocal_shapeCheck)
       (state, input, gradOutput, gradWeight, gradBias, kH, kW, dH, dW, padH, padW,
        inputHeight, inputWidth, outputHeight, outputWidth);

  input = THCTensor_(newContiguous)(state, input);
  gradOutput = THCTensor_(newContiguous)(state, gradOutput);

  long nInputPlane = THCTensor_(size)(state,gradWeight,2)/(kW*kH);
  long nOutputPlane = THCTensor_(size)(state,gradWeight,1);

  int batch = 1;
  if (input->nDimension == 3) {
    // Force batch
    batch = 0;
    THCTensor_(resize4d)(state, input, 1, nInputPlane, inputHeight, inputWidth);
    THCTensor_(resize4d)(state, gradOutput, 1, nOutputPlane, outputHeight, outputWidth);
  }

  // Batch size + input planes
  long batchSize = input->size[0];

  // Helpers
  THCTensor *input_n = THCTensor_(new)(state);
  THCTensor *finput_n = THCTensor_(new)(state);
  THCTensor *gradOutput_n = THCTensor_(new)(state);

  // For each elt in batch, do:
  for (int elt = 0; elt < batchSize; elt ++) {
    THCTensor *gradOutput3d, *finput3d;
    THCTensor *gwslice = THCTensor_(new)(state);
    THCTensor *islice = THCTensor_(new)(state);
    THCTensor *goslice = THCTensor_(new)(state);

    // Matrix mulitply per output:
    THCTensor_(select)(state, input_n, input, 0, elt);
    THCTensor_(select)(state, finput_n, finput, 0, elt);
    THCTensor_(select)(state, gradOutput_n, gradOutput, 0, elt);

    gradOutput3d = THCTensor_(newWithStorage3d)(state, gradOutput_n->storage, gradOutput_n->storageOffset,
                                                 outputHeight*outputWidth, 1,
                                                 nOutputPlane, outputHeight*outputWidth,
                                                 1, nOutputPlane*outputHeight*outputWidth);
    finput3d = THCTensor_(newWithStorage3d)(state, finput_n->storage, finput_n->storageOffset,
                                             outputHeight*outputWidth, 1,
                                             1, kW*kH*nInputPlane*outputHeight*outputWidth,
                                             kW*kH*nInputPlane, outputHeight*outputWidth);

    // Extract columns:
    im2col(
      THCState_getCurrentStream(state),
      THCTensor_(data)(state, input_n),
      nInputPlane, inputHeight, inputWidth, kH, kW, padH, padW, dH, dW,
      1, 1, THCTensor_(data)(state, finput_n)
    );

    for (int i = 0; i < outputHeight; i++) {
      for(int j = 0; j < outputWidth; j++) {
        int sliceidx = i * outputWidth + j;
        THCTensor_(select)(state, gwslice, gradWeight, 0, sliceidx);
        THCTensor_(select)(state, goslice, gradOutput3d, 0, sliceidx);
        THCTensor_(select)(state, islice, finput3d, 0, sliceidx);
        THCTensor_(addmm)(state, gwslice, ScalarConvert<int, real>::to(1), gwslice, scale, goslice, islice);
      }
    }
    // gradOutput3d:  oH*oW x nOutputPlane x 1
    // finput3d:      oH*oW x 1 x kW*kH*nInputPlane
    //THCTensor_(baddbmm)(state, gradWeight, 1.0, gradWeight, scale, gradOutput3d, finput3d);
    // gradWeight:    oH*oW x nOutputPlane x kW*kH*nInputPlane

    THCTensor_(cadd)(state, gradBias, gradBias, scale, gradOutput_n);

    THCTensor_(free)(state, gradOutput3d);
    THCTensor_(free)(state, finput3d);
    THCTensor_(free)(state, gwslice);
    THCTensor_(free)(state, goslice);
    THCTensor_(free)(state, islice);
  }

  // Free
  THCTensor_(free)(state, input_n);
  THCTensor_(free)(state, finput_n);
  THCTensor_(free)(state, gradOutput_n);

  // Resize
  if (batch == 0) {
    THCTensor_(resize3d)(state, gradOutput, nOutputPlane, outputHeight, outputWidth);
    THCTensor_(resize3d)(state, input, nInputPlane, inputHeight, inputWidth);
  }

  THCTensor_(free)(state, input);
  THCTensor_(free)(state, gradOutput);
  if (freeWeight)
     THCTensor_(free)(state, gradWeight);
}

#endif

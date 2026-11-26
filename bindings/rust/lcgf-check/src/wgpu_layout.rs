//! The layout of the webgpu.h structs `lcgf::gpu` (feature `wgpu`) declares, one line per
//! struct: size and field offsets, compared by bindings/check/run.sh with wgpu_layout.c.

use core::mem::{offset_of, size_of};
use lcgf::gpu::ffi::*;

pub fn print() {
    println!(
        "WGPUStringView {} {} {}",
        size_of::<WGPUStringView>(),
        offset_of!(WGPUStringView, data),
        offset_of!(WGPUStringView, length)
    );
    println!(
        "WGPUChainedStruct {} {} {}",
        size_of::<WGPUChainedStruct>(),
        offset_of!(WGPUChainedStruct, next),
        offset_of!(WGPUChainedStruct, sType)
    );
    println!(
        "WGPUBufferDescriptor {} {} {} {} {} {}",
        size_of::<WGPUBufferDescriptor>(),
        offset_of!(WGPUBufferDescriptor, nextInChain),
        offset_of!(WGPUBufferDescriptor, label),
        offset_of!(WGPUBufferDescriptor, usage),
        offset_of!(WGPUBufferDescriptor, size),
        offset_of!(WGPUBufferDescriptor, mappedAtCreation)
    );
    println!(
        "WGPUExtent3D {} {} {} {}",
        size_of::<WGPUExtent3D>(),
        offset_of!(WGPUExtent3D, width),
        offset_of!(WGPUExtent3D, height),
        offset_of!(WGPUExtent3D, depthOrArrayLayers)
    );
    println!(
        "WGPUOrigin3D {} {} {} {}",
        size_of::<WGPUOrigin3D>(),
        offset_of!(WGPUOrigin3D, x),
        offset_of!(WGPUOrigin3D, y),
        offset_of!(WGPUOrigin3D, z)
    );
    println!(
        "WGPUTextureDescriptor {} {} {} {} {} {} {} {} {} {} {}",
        size_of::<WGPUTextureDescriptor>(),
        offset_of!(WGPUTextureDescriptor, nextInChain),
        offset_of!(WGPUTextureDescriptor, label),
        offset_of!(WGPUTextureDescriptor, usage),
        offset_of!(WGPUTextureDescriptor, dimension),
        offset_of!(WGPUTextureDescriptor, size),
        offset_of!(WGPUTextureDescriptor, format),
        offset_of!(WGPUTextureDescriptor, mipLevelCount),
        offset_of!(WGPUTextureDescriptor, sampleCount),
        offset_of!(WGPUTextureDescriptor, viewFormatCount),
        offset_of!(WGPUTextureDescriptor, viewFormats)
    );
    println!(
        "WGPUSamplerDescriptor {} {} {} {} {} {} {} {} {} {} {} {} {}",
        size_of::<WGPUSamplerDescriptor>(),
        offset_of!(WGPUSamplerDescriptor, nextInChain),
        offset_of!(WGPUSamplerDescriptor, label),
        offset_of!(WGPUSamplerDescriptor, addressModeU),
        offset_of!(WGPUSamplerDescriptor, addressModeV),
        offset_of!(WGPUSamplerDescriptor, addressModeW),
        offset_of!(WGPUSamplerDescriptor, magFilter),
        offset_of!(WGPUSamplerDescriptor, minFilter),
        offset_of!(WGPUSamplerDescriptor, mipmapFilter),
        offset_of!(WGPUSamplerDescriptor, lodMinClamp),
        offset_of!(WGPUSamplerDescriptor, lodMaxClamp),
        offset_of!(WGPUSamplerDescriptor, compare),
        offset_of!(WGPUSamplerDescriptor, maxAnisotropy)
    );
    println!(
        "WGPUShaderSourceWGSL {} {} {}",
        size_of::<WGPUShaderSourceWGSL>(),
        offset_of!(WGPUShaderSourceWGSL, chain),
        offset_of!(WGPUShaderSourceWGSL, code)
    );
    println!(
        "WGPUShaderModuleDescriptor {} {} {}",
        size_of::<WGPUShaderModuleDescriptor>(),
        offset_of!(WGPUShaderModuleDescriptor, nextInChain),
        offset_of!(WGPUShaderModuleDescriptor, label)
    );
    println!(
        "WGPUVertexAttribute {} {} {} {} {}",
        size_of::<WGPUVertexAttribute>(),
        offset_of!(WGPUVertexAttribute, nextInChain),
        offset_of!(WGPUVertexAttribute, format),
        offset_of!(WGPUVertexAttribute, offset),
        offset_of!(WGPUVertexAttribute, shaderLocation)
    );
    println!(
        "WGPUVertexBufferLayout {} {} {} {} {} {}",
        size_of::<WGPUVertexBufferLayout>(),
        offset_of!(WGPUVertexBufferLayout, nextInChain),
        offset_of!(WGPUVertexBufferLayout, stepMode),
        offset_of!(WGPUVertexBufferLayout, arrayStride),
        offset_of!(WGPUVertexBufferLayout, attributeCount),
        offset_of!(WGPUVertexBufferLayout, attributes)
    );
    println!(
        "WGPUBlendComponent {} {} {} {}",
        size_of::<WGPUBlendComponent>(),
        offset_of!(WGPUBlendComponent, operation),
        offset_of!(WGPUBlendComponent, srcFactor),
        offset_of!(WGPUBlendComponent, dstFactor)
    );
    println!(
        "WGPUBlendState {} {} {}",
        size_of::<WGPUBlendState>(),
        offset_of!(WGPUBlendState, color),
        offset_of!(WGPUBlendState, alpha)
    );
    println!(
        "WGPUColorTargetState {} {} {} {} {}",
        size_of::<WGPUColorTargetState>(),
        offset_of!(WGPUColorTargetState, nextInChain),
        offset_of!(WGPUColorTargetState, format),
        offset_of!(WGPUColorTargetState, blend),
        offset_of!(WGPUColorTargetState, writeMask)
    );
    println!(
        "WGPUFragmentState {} {} {} {} {} {} {} {}",
        size_of::<WGPUFragmentState>(),
        offset_of!(WGPUFragmentState, nextInChain),
        offset_of!(WGPUFragmentState, module),
        offset_of!(WGPUFragmentState, entryPoint),
        offset_of!(WGPUFragmentState, constantCount),
        offset_of!(WGPUFragmentState, constants),
        offset_of!(WGPUFragmentState, targetCount),
        offset_of!(WGPUFragmentState, targets)
    );
    println!(
        "WGPUVertexState {} {} {} {} {} {} {} {}",
        size_of::<WGPUVertexState>(),
        offset_of!(WGPUVertexState, nextInChain),
        offset_of!(WGPUVertexState, module),
        offset_of!(WGPUVertexState, entryPoint),
        offset_of!(WGPUVertexState, constantCount),
        offset_of!(WGPUVertexState, constants),
        offset_of!(WGPUVertexState, bufferCount),
        offset_of!(WGPUVertexState, buffers)
    );
    println!(
        "WGPUPrimitiveState {} {} {} {} {} {} {}",
        size_of::<WGPUPrimitiveState>(),
        offset_of!(WGPUPrimitiveState, nextInChain),
        offset_of!(WGPUPrimitiveState, topology),
        offset_of!(WGPUPrimitiveState, stripIndexFormat),
        offset_of!(WGPUPrimitiveState, frontFace),
        offset_of!(WGPUPrimitiveState, cullMode),
        offset_of!(WGPUPrimitiveState, unclippedDepth)
    );
    println!(
        "WGPUMultisampleState {} {} {} {} {}",
        size_of::<WGPUMultisampleState>(),
        offset_of!(WGPUMultisampleState, nextInChain),
        offset_of!(WGPUMultisampleState, count),
        offset_of!(WGPUMultisampleState, mask),
        offset_of!(WGPUMultisampleState, alphaToCoverageEnabled)
    );
    println!(
        "WGPURenderPipelineDescriptor {} {} {} {} {} {} {} {} {}",
        size_of::<WGPURenderPipelineDescriptor>(),
        offset_of!(WGPURenderPipelineDescriptor, nextInChain),
        offset_of!(WGPURenderPipelineDescriptor, label),
        offset_of!(WGPURenderPipelineDescriptor, layout),
        offset_of!(WGPURenderPipelineDescriptor, vertex),
        offset_of!(WGPURenderPipelineDescriptor, primitive),
        offset_of!(WGPURenderPipelineDescriptor, depthStencil),
        offset_of!(WGPURenderPipelineDescriptor, multisample),
        offset_of!(WGPURenderPipelineDescriptor, fragment)
    );
    println!(
        "WGPUComputeState {} {} {} {} {} {}",
        size_of::<WGPUComputeState>(),
        offset_of!(WGPUComputeState, nextInChain),
        offset_of!(WGPUComputeState, module),
        offset_of!(WGPUComputeState, entryPoint),
        offset_of!(WGPUComputeState, constantCount),
        offset_of!(WGPUComputeState, constants)
    );
    println!(
        "WGPUComputePipelineDescriptor {} {} {} {} {}",
        size_of::<WGPUComputePipelineDescriptor>(),
        offset_of!(WGPUComputePipelineDescriptor, nextInChain),
        offset_of!(WGPUComputePipelineDescriptor, label),
        offset_of!(WGPUComputePipelineDescriptor, layout),
        offset_of!(WGPUComputePipelineDescriptor, compute)
    );
    println!(
        "WGPUBindGroupEntry {} {} {} {} {} {} {} {}",
        size_of::<WGPUBindGroupEntry>(),
        offset_of!(WGPUBindGroupEntry, nextInChain),
        offset_of!(WGPUBindGroupEntry, binding),
        offset_of!(WGPUBindGroupEntry, buffer),
        offset_of!(WGPUBindGroupEntry, offset),
        offset_of!(WGPUBindGroupEntry, size),
        offset_of!(WGPUBindGroupEntry, sampler),
        offset_of!(WGPUBindGroupEntry, textureView)
    );
    println!(
        "WGPUBindGroupDescriptor {} {} {} {} {} {}",
        size_of::<WGPUBindGroupDescriptor>(),
        offset_of!(WGPUBindGroupDescriptor, nextInChain),
        offset_of!(WGPUBindGroupDescriptor, label),
        offset_of!(WGPUBindGroupDescriptor, layout),
        offset_of!(WGPUBindGroupDescriptor, entryCount),
        offset_of!(WGPUBindGroupDescriptor, entries)
    );
    println!(
        "WGPUColor {} {} {} {} {}",
        size_of::<WGPUColor>(),
        offset_of!(WGPUColor, r),
        offset_of!(WGPUColor, g),
        offset_of!(WGPUColor, b),
        offset_of!(WGPUColor, a)
    );
    println!(
        "WGPURenderPassColorAttachment {} {} {} {} {} {} {} {}",
        size_of::<WGPURenderPassColorAttachment>(),
        offset_of!(WGPURenderPassColorAttachment, nextInChain),
        offset_of!(WGPURenderPassColorAttachment, view),
        offset_of!(WGPURenderPassColorAttachment, depthSlice),
        offset_of!(WGPURenderPassColorAttachment, resolveTarget),
        offset_of!(WGPURenderPassColorAttachment, loadOp),
        offset_of!(WGPURenderPassColorAttachment, storeOp),
        offset_of!(WGPURenderPassColorAttachment, clearValue)
    );
    println!(
        "WGPURenderPassDescriptor {} {} {} {} {} {} {} {}",
        size_of::<WGPURenderPassDescriptor>(),
        offset_of!(WGPURenderPassDescriptor, nextInChain),
        offset_of!(WGPURenderPassDescriptor, label),
        offset_of!(WGPURenderPassDescriptor, colorAttachmentCount),
        offset_of!(WGPURenderPassDescriptor, colorAttachments),
        offset_of!(WGPURenderPassDescriptor, depthStencilAttachment),
        offset_of!(WGPURenderPassDescriptor, occlusionQuerySet),
        offset_of!(WGPURenderPassDescriptor, timestampWrites)
    );
    println!(
        "WGPUTexelCopyTextureInfo {} {} {} {} {}",
        size_of::<WGPUTexelCopyTextureInfo>(),
        offset_of!(WGPUTexelCopyTextureInfo, texture),
        offset_of!(WGPUTexelCopyTextureInfo, mipLevel),
        offset_of!(WGPUTexelCopyTextureInfo, origin),
        offset_of!(WGPUTexelCopyTextureInfo, aspect)
    );
    println!(
        "WGPUTexelCopyBufferLayout {} {} {} {}",
        size_of::<WGPUTexelCopyBufferLayout>(),
        offset_of!(WGPUTexelCopyBufferLayout, offset),
        offset_of!(WGPUTexelCopyBufferLayout, bytesPerRow),
        offset_of!(WGPUTexelCopyBufferLayout, rowsPerImage)
    );
    println!(
        "WGPUTexelCopyBufferInfo {} {} {}",
        size_of::<WGPUTexelCopyBufferInfo>(),
        offset_of!(WGPUTexelCopyBufferInfo, layout),
        offset_of!(WGPUTexelCopyBufferInfo, buffer)
    );
    println!(
        "WGPUBufferMapCallbackInfo {} {} {} {} {} {}",
        size_of::<WGPUBufferMapCallbackInfo>(),
        offset_of!(WGPUBufferMapCallbackInfo, nextInChain),
        offset_of!(WGPUBufferMapCallbackInfo, mode),
        offset_of!(WGPUBufferMapCallbackInfo, callback),
        offset_of!(WGPUBufferMapCallbackInfo, userdata1),
        offset_of!(WGPUBufferMapCallbackInfo, userdata2)
    );
    println!(
        "WGPUFuture {} {}",
        size_of::<WGPUFuture>(),
        offset_of!(WGPUFuture, id)
    );
}

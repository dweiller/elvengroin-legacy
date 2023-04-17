#include "common.hlsli"
#include "pbr.hlsli"
#include "gbuffer.hlsli"

#define ROOT_SIGNATURE \
    "RootFlags(CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED), " \
    "CBV(b0), " \
    "CBV(b1), " \
    "CBV(b2), " \
    "StaticSampler(s0, filter = FILTER_ANISOTROPIC, maxAnisotropy = 16, visibility = SHADER_VISIBILITY_ALL, addressU = TEXTURE_ADDRESS_CLAMP, addressV = TEXTURE_ADDRESS_CLAMP, addressW = TEXTURE_ADDRESS_CLAMP), " \
    "StaticSampler(s1, filter = FILTER_ANISOTROPIC, maxAnisotropy = 16, visibility = SHADER_VISIBILITY_ALL, addressU = TEXTURE_ADDRESS_WRAP, addressV = TEXTURE_ADDRESS_WRAP, addressW = TEXTURE_ADDRESS_WRAP), " \
    "StaticSampler(s2, filter = FILTER_MIN_MAG_MIP_LINEAR, visibility = SHADER_VISIBILITY_ALL, addressU = TEXTURE_ADDRESS_CLAMP, addressV = TEXTURE_ADDRESS_CLAMP, addressW = TEXTURE_ADDRESS_CLAMP), " \
    "StaticSampler(s3, filter = FILTER_MIN_MAG_MIP_LINEAR, visibility = SHADER_VISIBILITY_ALL, addressU = TEXTURE_ADDRESS_WRAP, addressV = TEXTURE_ADDRESS_WRAP, addressW = TEXTURE_ADDRESS_WRAP), " \
    "StaticSampler(s4, filter = FILTER_ANISOTROPIC, maxAnisotropy = 16, visibility = SHADER_VISIBILITY_PIXEL)"

SamplerState sam_aniso_clamp : register(s0);
SamplerState sam_aniso_wrap : register(s1);
SamplerState sam_linear_clamp : register(s2);
SamplerState sam_linear_wrap : register(s3);

struct Vertex {
    float3 position;
    float3 normal;
    float2 uv;
    float4 tangent;
    float3 color;
};

struct DrawConst {
    uint start_instance_location;
    int vertex_offset;
    uint vertex_buffer_index;
    uint instance_transform_buffer_index;
    uint instance_material_buffer_index;
};

struct InstanceTransform {
    float4x4 object_to_world;
};

struct InstanceMaterial {
    float4 albedo_color;
    float roughness;
    float metallic;
    float normal_intensity;
    uint albedo_texture_index;
    uint emissive_texture_index;
    uint normal_texture_index;
    uint arm_texture_index;
    uint padding;
};

ConstantBuffer<DrawConst> cbv_draw_const : register(b0);
ConstantBuffer<FrameConst> cbv_frame_const : register(b1);
ConstantBuffer<SceneConst> cbv_scene_const : register(b2);

struct InstancedVertexOut {
    float4 position_vs : SV_Position;
    float3 position : TEXCOORD0;
    float2 uv : TEXCOORD1;
    float3 normal : NORMAL;
    float4 tangent : TANGENT;
    float3 color : COLOR;
    uint instanceID: SV_InstanceID;
};

[RootSignature(ROOT_SIGNATURE)]
InstancedVertexOut vsInstanced(uint vertex_id : SV_VertexID, uint instanceID : SV_InstanceID) {
    InstancedVertexOut output = (InstancedVertexOut)0;
    output.instanceID = instanceID;

    ByteAddressBuffer vertex_buffer = ResourceDescriptorHeap[cbv_draw_const.vertex_buffer_index];
    Vertex vertex = vertex_buffer.Load<Vertex>((vertex_id + cbv_draw_const.vertex_offset) * sizeof(Vertex));

    ByteAddressBuffer instance_transform_buffer = ResourceDescriptorHeap[cbv_draw_const.instance_transform_buffer_index];
    uint instance_index = instanceID + cbv_draw_const.start_instance_location;
    InstanceTransform instance = instance_transform_buffer.Load<InstanceTransform>(instance_index * sizeof(InstanceTransform));

    const float4x4 object_to_clip = mul(instance.object_to_world, cbv_frame_const.world_to_clip);
    output.position_vs = mul(float4(vertex.position, 1.0), object_to_clip);
    output.position = mul(float4(vertex.position, 1.0), instance.object_to_world).xyz;
    output.uv = vertex.uv;
    output.normal = vertex.normal; // object-space normal
    output.tangent = vertex.tangent;
    output.color = vertex.color;

    return output;
}

[RootSignature(ROOT_SIGNATURE)]
GBufferTargets psInstanced(InstancedVertexOut input) {
    ByteAddressBuffer instance_material_buffer = ResourceDescriptorHeap[cbv_draw_const.instance_material_buffer_index];
    uint instance_index = input.instanceID + cbv_draw_const.start_instance_location;
    InstanceMaterial material = instance_material_buffer.Load<InstanceMaterial>(instance_index * sizeof(InstanceMaterial));

    ByteAddressBuffer instance_transform_buffer = ResourceDescriptorHeap[cbv_draw_const.instance_transform_buffer_index];
    InstanceTransform instance = instance_transform_buffer.Load<InstanceTransform>(instance_index * sizeof(InstanceTransform));

    // Compute TBN matrix
    float3x3 TBN = 0.0f;
    if (has_valid_texture(material.normal_texture_index))
    {
        TBN = makeTBN(input.normal.xyz, input.tangent.xyz);
    }

    // Albedo
    float4 albedo = material.albedo_color;
    if (has_valid_texture(material.albedo_texture_index))
    {
        Texture2D albedo_texture = ResourceDescriptorHeap[material.albedo_texture_index];
        float3 albedo_sample = albedo_texture.Sample(sam_aniso_wrap, input.uv).rgb;
        albedo_sample.rgb = degamma(albedo_sample.rgb);
        albedo.rgb *= albedo_sample.rgb;
        albedo.a = 1.0;
    }

    // Roughness, Metallic and Occlusion
    float roughness = material.roughness;
    float metallic = material.metallic;
    float occlusion = 1.0f;
    if (has_valid_texture(material.arm_texture_index))
    {
        Texture2D arm_texture = ResourceDescriptorHeap[material.arm_texture_index];
        float3 arm = arm_texture.Sample(sam_aniso_wrap, input.uv).rgb;
        roughness *= arm.g;
        metallic *= arm.b;
        occlusion *= arm.r;
    }

    // Normal
    float3 normal = input.normal.xyz;
    if (has_valid_texture(material.normal_texture_index))
    {
        Texture2D normal_texture = ResourceDescriptorHeap[material.normal_texture_index];
        float3 tangent_normal = normalize(unpack(normal_texture.Sample(sam_aniso_wrap, input.uv).rgb));
        float normal_intensity = clamp(material.normal_intensity, 0.012f, material.normal_intensity);
        tangent_normal.xy *= saturate(normal_intensity);
        normal = normalize(mul(tangent_normal, TBN));
    }

    // Emission
    float emission = 0.0f;
    if (has_valid_texture(material.emissive_texture_index))
    {
        Texture2D emissive_texture = ResourceDescriptorHeap[material.emissive_texture_index];
        float3 emissive_color = emissive_texture.Sample(sam_aniso_wrap, input.uv).rgb;
        emission = luminance(emissive_color);
        albedo.rgb += emissive_color;
    }

    GBufferTargets gbuffer;
    gbuffer.albedo = albedo;
    gbuffer.normal = float4(normal, 0.0);
    gbuffer.material = float4(roughness, metallic, emission, occlusion);
    return gbuffer;
}
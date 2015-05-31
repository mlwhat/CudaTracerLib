#include "k_TraceAlgorithms.h"
#include "../Engine/e_Samples.h"
#include "../Engine/e_Material.h"
#include "../Engine/e_Light.h"

//#define EXT_EST

CUDA_FUNC_IN Spectrum EstimateDirect(BSDFSamplingRecord bRec, const e_KernelMaterial& mat, const e_KernelLight* light, unsigned int li, EBSDFType flags, CudaRNG& rng)
{
#ifndef EXT_EST
	DirectSamplingRecord dRec(bRec.dg.P, bRec.dg.sys.n);
	Spectrum value = light->sampleDirect(dRec, rng.randomFloat2());
	Spectrum retVal(0.0f);
	if(!value.isZero())
	{
		Vec3f oldWo = bRec.wo;
		bRec.wo = normalize(bRec.dg.toLocal(dRec.d));
		bRec.typeMask = flags;
		Spectrum bsdfVal = mat.bsdf.f(bRec);
		if (!bsdfVal.isZero() && !g_SceneData.Occluded(Ray(dRec.ref, dRec.d), 0, dRec.dist))
		{
			const float bsdfPdf = mat.bsdf.pdf(bRec);
			const float weight = MonteCarlo::PowerHeuristic(1, dRec.pdf, 1, bsdfPdf);
			retVal = value * bsdfVal * weight;
		}
		bRec.typeMask = EAll;
		bRec.wo = oldWo;
	}
	return retVal;
#else	
	Spectrum Ld = make_float3(0.0f);
	float lightPdf, bsdfPdf;
	DirectSamplingRecord dRec(bRec.map.P, bRec.map.sys.n);
	Spectrum Li = light->sampleDirect(dRec, rng.randomFloat2());
	lightPdf = dRec.pdf;
	if(lightPdf > 0.0f && !Li.isZero())
	{
		bRec.wo = bRec.map.sys.toLocal(dRec.d);
		Spectrum f = mat.bsdf.f(bRec);
		Ray r(dRec.ref, dRec.d);
		if(!f.isZero() && !g_SceneData.Occluded(r, 0, dRec.dist))
		{
			Li = Li * Transmittance(r, 0, dRec.dist);
			if(light->IsDeltaLight())
				Ld += f * Li * absdot(r.direction, bRec.map.sys.n);
			else
			{
				bRec.typeMask = flags;
				bsdfPdf = mat.bsdf.pdf(bRec);
				float weight = MonteCarlo::PowerHeuristic(1, lightPdf, 1, bsdfPdf);
				Ld += f * Li * absdot(r.direction, bRec.map.sys.n) * weight;
				bRec.typeMask = EAll;
			}
		}
	}
	
	if(!light->IsDeltaLight())
	{
		bRec.typeMask = flags;
		Spectrum f = mat.bsdf.sample(bRec, rng.randomFloat2());
		Vec3f wi = bRec.map.sys.toWorld(bRec.wo);
		if(!f.isZero() && bsdfPdf > 0.0f)
		{
			float weight = 1.0f;
			if (!(bRec.sampledType & EDelta))
			{
                if (lightPdf == 0.0f)
                    return Ld;
                weight = MonteCarlo::PowerHeuristic(1, bsdfPdf, 1, lightPdf);
            }
			Spectrum Li = make_float3(0.0f);
			TraceResult r2;
			r2.Init();
			if(k_TraceRay(wi, bRec.map.P, &r2) && r2.LightIndex() == li)
				Li = r2.Le(bRec.map.P, bRec.map.sys.n, -wi);
			else Li = light->eval(bRec.map.P, bRec.map.sys, wi);
			if(!Li.isZero())
			{
				Li = Li * Transmittance(Ray(bRec.map.P, wi), 0, r2.m_fDist);
				Ld += Li * f * absdot(wi, bRec.map.sys.n) * weight;
			}
		}
	}

	return Ld;
#endif
}

Spectrum UniformSampleAllLights(const BSDFSamplingRecord& bRec, const e_KernelMaterial& mat, int nSamples, CudaRNG& rng)
{
	//only sample the relevant lights and assume the others emit the same
	Spectrum L = Spectrum(0.0f);
	for(unsigned int i = 0; i < g_SceneData.m_uEmitterCount; i++)
	{
		unsigned int l = g_SceneData.m_uEmitterIndices[i];
		e_KernelLight* light = g_SceneData.m_sLightData.Data + l;
		if(light->As()->IsRemoved)
			continue;
		Spectrum Ld = Spectrum(0.0f);
		for(int j = 0; j < nSamples; j++)
		{
			Ld += EstimateDirect((BSDFSamplingRecord&)bRec, mat, light, l, EBSDFType(EAll & ~EDelta), rng);
		}
		L += Ld / float(nSamples);
	}
	return L;
}

Spectrum UniformSampleOneLight(const BSDFSamplingRecord& bRec, const e_KernelMaterial& mat, CudaRNG& rng)
{
	if(!g_SceneData.m_uEmitterCount)
		return Spectrum(0.0f);
	float emitpdf;
	unsigned int index = g_SceneData.m_uEmitterIndices[g_SceneData.m_emitterPDF.SampleDiscrete(rng.randomFloat(), &emitpdf)];
	return float(g_SceneData.m_uEmitterCount) * EstimateDirect((BSDFSamplingRecord&)bRec, mat, g_SceneData.m_sLightData.Data + index, index, EBSDFType(EAll & ~EDelta), rng);
}
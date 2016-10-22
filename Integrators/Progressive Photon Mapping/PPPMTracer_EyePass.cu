#include "PPPMTracer.h"
#include <Kernel/TraceHelper.h>
#include <Kernel/TraceAlgorithms.h>
#include <Math/half.h>
#include <Engine/Light.h>
#include <Engine/SpatialGridTraversal.h>
#include <Base/RuntimeTemplateHelper.h>

#define LOOKUP_NORMAL_THRESH 0.5f

namespace CudaTracerLib {

template<bool USE_GLOBAL> Spectrum PointStorage::L_Volume(float rad, float NumEmitted, const NormalizedT<Ray>& r, float tmin, float tmax, const VolHelper<USE_GLOBAL>& vol, Spectrum& Tr, float& pl_est)
{
	Spectrum Tau = Spectrum(0.0f);
	Spectrum L_n = Spectrum(0.0f);
	float a, b;
	if (!m_sStorage.getHashGrid().getAABB().Intersect(r, &a, &b))
		return L_n;//that would be dumb
	float minT = a = math::clamp(a, tmin, tmax);
	b = math::clamp(b, tmin, tmax);
	float d = 2.0f * rad;
	float pl = 0, num_est;
	while (a < b)
	{
		float t = a + d / 2.0f;
		Vec3f x = r(t);
		Spectrum L_i(0.0f);
		m_sStorage.ForAll(x - Vec3f(rad), x + Vec3f(rad), [&](const Vec3u& cell_idx, unsigned int p_idx, const _VolumetricPhoton& ph)
		{
			Vec3f ph_pos = ph.getPos(m_sStorage.getHashGrid(), cell_idx);
			auto dist2 = distanceSquared(ph_pos, x);
			if (dist2 < math::sqr(rad))
			{
				PhaseFunctionSamplingRecord pRec(-r.dir(), ph.getWi());
				float p = vol.p(x, pRec);
				float k = Kernel::k<3>(math::sqrt(dist2), rad);
				L_i += p * ph.getL() / NumEmitted * k;
				pl += k;
			}
		});
		L_n += (-Tau - vol.tau(r, a, t)).exp() * L_i * d;
		Tau += vol.tau(r, a, a + d);
		L_n += vol.Lve(x, -r.dir()) * d;
		a += d;
		num_est++;
	}
	Tr = (-Tau).exp();
	pl_est += pl / num_est;
	return L_n;
}

template<bool USE_GLOBAL> Spectrum BeamGrid::L_Volume(float rad, float NumEmitted, const NormalizedT<Ray>& r, float tmin, float tmax, const VolHelper<USE_GLOBAL>& vol, Spectrum& Tr, float& pl_est)
{
	Spectrum Tau = Spectrum(0.0f);
	Spectrum L_n = Spectrum(0.0f);
	TraverseGridRay(r, m_sStorage.getHashGrid(), tmin, tmax, [&](float minT, float rayT, float maxT, float cellEndT, const Vec3u& cell_pos, bool& cancelTraversal)
	{
		m_sBeamGridStorage.ForAllCellEntries(cell_pos, [&](unsigned int, entry beam_idx)
		{
			const auto& ph = m_sStorage(beam_idx.getIndex());
			Vec3f ph_pos = ph.getPos(m_sStorage.getHashGrid(), cell_pos);
			float ph_rad1 = ph.getRad1(), ph_rad2 = math::sqr(ph_rad1);
			float l1 = dot(ph_pos - r.ori(), r.dir());
			float isectRadSqr = distanceSquared(ph_pos, r(l1));
			if (isectRadSqr < ph_rad2 && rayT <= l1 && l1 <= cellEndT)
			{
				//transmittance from camera vertex along ray to query point
				Spectrum tauToPhoton = (-Tau - vol.tau(r, rayT, l1)).exp();
				PhaseFunctionSamplingRecord pRec(-r.dir(), ph.getWi());
				float p = vol.p(ph_pos, pRec);
				L_n += p * ph.getL() / NumEmitted * tauToPhoton * Kernel::k<2>(math::sqrt(isectRadSqr), ph_rad1);
			}
			/*float t1, t2;
			if (sphere_line_intersection(ph_pos, ph_rad2, r, t1, t2))
			{
				float t = (t1 + t2) / 2;
				auto b = r(t);
				float dist = distance(b, ph_pos);
				auto o_s = vol.sigma_s(b, r.dir()), o_a = vol.sigma_a(b, r.dir()), o_t = Spectrum(o_s + o_a);
				if (dist < ph_rad1 && rayT <= t && t <= cellEndT)
				{
					PhaseFunctionSamplingRecord pRec(-r.dir(), ph.getWi());
					float p = vol.p(b, pRec);

					//auto T1 = (-vol.tau(r, 0, t1)).exp(), T2 = (-vol.tau(r, 0, t2)).exp(),
					//	 ta = (t2 - t1) * (T1 + 0.5 * (T2 - T1));
					//L_n += p * ph.getL() / NumEmitted * Kernel::k<3>(dist, ph_rad1) * ta;
					auto Tr_c = (-vol.tau(r, 0, t)).exp();
					L_n += p * ph.getL() / NumEmitted * Kernel::k<3>(dist, ph_rad1) * Tr_c * (t2 - t1);
				}
			}*/
		});
		Tau += vol.tau(r, rayT, cellEndT);
		float localDist = cellEndT - rayT;
		L_n += vol.Lve(r(rayT + localDist / 2), -r.dir()) * localDist;
	});
	Tr = (-Tau).exp();

	return L_n;
}

template<bool USE_GLOBAL> Spectrum BeamBeamGrid::L_Volume(float rad, float NumEmitted, const NormalizedT<Ray>& r, float tmin, float tmax, const VolHelper<USE_GLOBAL>& vol, Spectrum& Tr, float& pl_est)
{
	Spectrum L_n = Spectrum(0.0f), Tau = Spectrum(0.0f);
	int nPhotons = 0;

	for (unsigned int i = 0; i < min(m_uBeamIdx, m_sBeamStorage.getLength()); i++)
	{
		const Beam& B = m_sBeamStorage[i];
		float beamBeamDistance, sinTheta, queryIsectDist, beamIsectDist;
		if (Beam::testIntersectionBeamBeam(r.ori(), r.dir(), tmin, tmax, B.getPos(), B.getDir(), 0, B.t, math::sqr(rad), beamBeamDistance, sinTheta, queryIsectDist, beamIsectDist))
		{
			nPhotons++;
			Spectrum photon_tau = vol.tau(Ray(B.getPos(), B.getDir()), 0, beamIsectDist);
			Spectrum camera_tau = vol.tau(r, tmin, queryIsectDist);
			Spectrum camera_sc = vol.sigma_s(r(queryIsectDist), r.dir());
			PhaseFunctionSamplingRecord pRec(-r.dir(), B.getDir());
			float p = vol.p(r(queryIsectDist), pRec);
			L_n += B.getL() / NumEmitted * (-photon_tau).exp() * camera_sc * Kernel::k<1>(beamBeamDistance, rad) / sinTheta * (-camera_tau).exp();//this is not correct; the phase function is missing
		}
	}
	Tr = (-vol.tau(r, tmin, tmax)).exp();
	pl_est += nPhotons / (PI * rad * rad * (tmax - tmin));
	return L_n;
}

CUDA_CONST CudaStaticWrapper<SurfaceMapT> g_SurfMap;
CUDA_CONST CudaStaticWrapper<SurfaceMapT> g_SurfMapCaustic;
CUDA_CONST unsigned int g_NumPhotonEmittedSurface2, g_NumPhotonEmittedVolume2;
CUDA_CONST CUDA_ALIGN(16) unsigned char g_VolEstimator2[Dmax3(sizeof(PointStorage), sizeof(BeamGrid), sizeof(BeamBeamGrid))];

CUDA_FUNC_IN Spectrum L_Surface(BSDFSamplingRecord& bRec, const NormalizedT<Vec3f>& wi, float r, const Material& mat, unsigned int numPhotonsEmitted, float& pl_est, SurfaceMapT* map = 0)
{
	if (!map) map = &g_SurfMap.As();
	bool hasGlossy = mat.bsdf.hasComponent(EGlossy);
	Spectrum Lp = Spectrum(0.0f);
	Vec3f a = r*(-bRec.dg.sys.t - bRec.dg.sys.s) + bRec.dg.P, b = r*(bRec.dg.sys.t - bRec.dg.sys.s) + bRec.dg.P, c = r*(-bRec.dg.sys.t + bRec.dg.sys.s) + bRec.dg.P, d = r*(bRec.dg.sys.t + bRec.dg.sys.s) + bRec.dg.P;
	map->ForAll(min(a, b, c, d), max(a, b, c, d), [&](const Vec3u& cell_idx, unsigned int p_idx, const PPPMPhoton& ph)
	{
		float dist2 = distanceSquared(ph.getPos(map->getHashGrid(), cell_idx), bRec.dg.P);
		Vec3f photonNormal = ph.getNormal();
		float wiDotGeoN = absdot(photonNormal, wi);
		if (dist2 < r * r && dot(photonNormal, bRec.dg.sys.n) > LOOKUP_NORMAL_THRESH && wiDotGeoN > 1e-2f)
		{
			bRec.wo = bRec.dg.toLocal(ph.getWi());
			float cor_fac = math::abs(Frame::cosTheta(bRec.wi) / (wiDotGeoN * Frame::cosTheta(bRec.wo)));
			float ke = Kernel::k<2>(math::sqrt(dist2), r);
			Spectrum l = ph.getL();
			if(hasGlossy)
				l *= mat.bsdf.f(bRec) / Frame::cosTheta(bRec.wo);//bsdf.f returns f * cos(thetha)
			Lp += ke * l;
			pl_est += ke;
		}
	});

	if(!hasGlossy)
	{
		auto wi_l = bRec.wi;
		bRec.wo = bRec.wi = NormalizedT<Vec3f>(0.0f, 0.0f, 1.0f);
		Lp *= mat.bsdf.f(bRec);
		bRec.wi = wi_l;
	}

	return Lp / (float)numPhotonsEmitted;
}

CUDA_FUNC_IN Spectrum L_SurfaceFinalGathering(int N_FG_Samples, BSDFSamplingRecord& bRec, const NormalizedT<Vec3f>& wi, float rad, TraceResult& r2, Sampler& rng, bool DIRECT, unsigned int numPhotonsEmitted, float& pl_est)
{
	Spectrum LCaustic = L_Surface(bRec, wi, rad, r2.getMat(), numPhotonsEmitted, pl_est, &g_SurfMapCaustic.As());
	if (!DIRECT)
		LCaustic += UniformSampleOneLight(bRec, r2.getMat(), rng);//the direct light is not stored in the caustic map
	Spectrum L(0.0f);
	DifferentialGeometry dg;
	BSDFSamplingRecord bRec2(dg);//constantly reloading into bRec and using less registers has about the same performance
	bRec.typeMask = EGlossy | EDiffuse;
	for (int i = 0; i < N_FG_Samples; i++)
	{
		Spectrum f = r2.getMat().bsdf.sample(bRec, rng.randomFloat2());
		NormalizedT<Ray> r(bRec.dg.P, bRec.getOutgoing());
		TraceResult r3 = traceRay(r);
		if (r3.hasHit())
		{
			r3.getBsdfSample(r, bRec2, ETransportMode::ERadiance);
			float _;
			L += f * L_Surface(bRec2, -r.dir(), rad, r3.getMat(), numPhotonsEmitted, _) + L_Surface(bRec2, -r.dir(), rad, r3.getMat(), numPhotonsEmitted, _, &g_SurfMapCaustic.As());
			L += f * UniformSampleOneLight(bRec2, r3.getMat(), rng);
			//do not account for emission because this was sampled before
		}
	}
	bRec.typeMask = ETypeCombinations::EAll;
	return L / (float)N_FG_Samples + LCaustic;
}

template<typename VolEstimator>  __global__ void k_EyePass(Vec2i off, int w, int h, k_AdaptiveStruct a_AdpEntries, BlockSampleImage img, bool DIRECT, int N_FG_Samples)
{
	auto rng = g_SamplerData();
	DifferentialGeometry dg;
	BSDFSamplingRecord bRec(dg);
	Vec2i pixel = TracerBase::getPixelPos(off.x, off.y);
	if (pixel.x < w && pixel.y < h)
	{
		auto adp_ent = a_AdpEntries(pixel.x, pixel.y);
		float rad_surf = a_AdpEntries.getRadiusSurf(adp_ent), rad_vol = a_AdpEntries.getRadiusVol<VolEstimator::DIM()>(adp_ent);
		float vol_dens_est_it = 0;
		int numVolEstimates = 0;

		Vec2f screenPos = Vec2f(pixel.x, pixel.y) + rng.randomFloat2();
		NormalizedT<Ray> r, rX, rY;
		Spectrum throughput = g_SceneData.sampleSensorRay(r, rX, rY, screenPos, rng.randomFloat2());

		TraceResult r2;
		r2.Init();
		int depth = -1;
		Spectrum L(0.0f);
		while (traceRay(r.dir(), r.ori(), &r2) && depth++ < 5)
		{
			r2.getBsdfSample(r, bRec, ETransportMode::ERadiance);
			if (depth == 0)
				dg.computePartials(r, rX, rY);
			if (g_SceneData.m_sVolume.HasVolumes())
			{
				float tmin, tmax;
				if (g_SceneData.m_sVolume.IntersectP(r, 0, r2.m_fDist, &tmin, &tmax))
				{
					Spectrum Tr(1.0f);
					L += throughput * ((VolEstimator*)g_VolEstimator2)->L_Volume(rad_vol, g_NumPhotonEmittedVolume2, r, tmin, tmax, VolHelper<true>(), Tr, vol_dens_est_it);
					numVolEstimates++;
					throughput = throughput * Tr;
				}
			}
			if (DIRECT && (!g_SceneData.m_sVolume.HasVolumes() || (g_SceneData.m_sVolume.HasVolumes() && depth == 0)))
			{
				float pdf;
				Vec2f sample = rng.randomFloat2();
				const Light* light = g_SceneData.sampleEmitter(pdf, sample);
				DirectSamplingRecord dRec(bRec.dg.P, bRec.dg.sys.n);
				Spectrum value = light->sampleDirect(dRec, rng.randomFloat2()) / pdf;
				bRec.wo = bRec.dg.toLocal(dRec.d);
				bRec.typeMask = EBSDFType(EAll & ~EDelta);
				Spectrum bsdfVal = r2.getMat().bsdf.f(bRec);
				if (!bsdfVal.isZero())
				{
					const float bsdfPdf = r2.getMat().bsdf.pdf(bRec);
					const float weight = MonteCarlo::PowerHeuristic(1, dRec.pdf, 1, bsdfPdf);
					if (g_SceneData.Occluded(Ray(dRec.ref, dRec.d), 0, dRec.dist))
						value = 0.0f;
					float tmin, tmax;
					if (g_SceneData.m_sVolume.HasVolumes() && g_SceneData.m_sVolume.IntersectP(Ray(bRec.dg.P, dRec.d), 0, dRec.dist, &tmin, &tmax))
					{
						Spectrum Tr;
						Spectrum Li = ((VolEstimator*)g_VolEstimator2)->L_Volume(rad_vol, g_NumPhotonEmittedVolume2, NormalizedT<Ray>(bRec.dg.P, dRec.d), tmin, tmax, VolHelper<true>(), Tr, vol_dens_est_it);
						numVolEstimates++;
						value = value * Tr + Li;
					}
					L += throughput * bsdfVal * weight * value;
				}
				bRec.typeMask = EAll;
				
				//L += throughput * UniformSampleOneLight(bRec, r2.getMat(), rng);
			}
			L += throughput * r2.Le(bRec.dg.P, bRec.dg.sys, -r.dir());//either it's the first bounce or it's a specular reflection
			const VolumeRegion* bssrdf;
			if (r2.getMat().GetBSSRDF(bRec.dg, &bssrdf))
			{
				float pdf;
				Spectrum t_f = r2.getMat().bsdf.sample(bRec, pdf, rng.randomFloat2());
				bRec.wo.z *= -1.0f;
				NormalizedT<Ray> rTrans = NormalizedT<Ray>(bRec.dg.P, bRec.getOutgoing());
				TraceResult r3 = traceRay(rTrans);
				Spectrum Tr;
				L += throughput * ((VolEstimator*)g_VolEstimator2)->L_Volume(rad_vol, g_NumPhotonEmittedVolume2, rTrans, 0, r3.m_fDist, VolHelper<false>(bssrdf), Tr, vol_dens_est_it);
				numVolEstimates++;
				//throughput = throughput * Tr;
				break;
			}
			bool hasDiffuse = r2.getMat().bsdf.hasComponent(EDiffuse),
				hasSpec = r2.getMat().bsdf.hasComponent(EDelta),
				hasGlossy = r2.getMat().bsdf.hasComponent(EGlossy);
			if (hasDiffuse)
			{
				Spectrum L_r;//reflected radiance computed by querying photon map
				float pl_est_it = 0;
				L_r = N_FG_Samples != 0 ? L_SurfaceFinalGathering(N_FG_Samples, bRec, -r.dir(), rad_surf, r2, rng, DIRECT, g_NumPhotonEmittedSurface2, pl_est_it) :
										  L_Surface(bRec, -r.dir(), rad_surf, r2.getMat(), g_NumPhotonEmittedSurface2, pl_est_it);
				adp_ent.surf_density.addSample(pl_est_it);
				L += throughput * L_r;
				if (!hasSpec && !hasGlossy)
					break;
			}
			if (hasSpec || hasGlossy)
			{
				bRec.sampledType = 0;
				bRec.typeMask = EDelta | EGlossy;
				Spectrum t_f = r2.getMat().bsdf.sample(bRec, rng.randomFloat2());
				if (!bRec.sampledType)
					break;
				throughput = throughput * t_f;
				r = NormalizedT<Ray>(bRec.dg.P, bRec.getOutgoing());
				r2.Init();
			}
			else break;
		}

		if (!r2.hasHit())
		{
			Spectrum Tr(1);
			float tmin, tmax;
			if (g_SceneData.m_sVolume.HasVolumes() && g_SceneData.m_sVolume.IntersectP(r, 0, r2.m_fDist, &tmin, &tmax))
			{
				L += throughput * ((VolEstimator*)g_VolEstimator2)->L_Volume(rad_vol, (float)g_NumPhotonEmittedVolume2, r, tmin, tmax, VolHelper<true>(), Tr, vol_dens_est_it);
				numVolEstimates++;
			}
			L += Tr * throughput * g_SceneData.EvalEnvironment(r);
		}

		img.Add(screenPos.x, screenPos.y, L);
		adp_ent.vol_density.addSample(vol_dens_est_it / numVolEstimates);
		a_AdpEntries(pixel.x, pixel.y) = adp_ent;
	}
	g_SamplerData(rng);
}

void PPPMTracer::RenderBlock(Image* I, int x, int y, int blockW, int blockH)
{
	ThrowCudaErrors(cudaMemcpyToSymbol(g_SurfMap, &m_sSurfaceMap, sizeof(m_sSurfaceMap)));
	if (m_sSurfaceMapCaustic)
		ThrowCudaErrors(cudaMemcpyToSymbol(g_SurfMapCaustic, m_sSurfaceMapCaustic, sizeof(*m_sSurfaceMapCaustic)));
	ThrowCudaErrors(cudaMemcpyToSymbol(g_NumPhotonEmittedSurface2, &m_uPhotonEmittedPassSurface, sizeof(m_uPhotonEmittedPassSurface)));
	ThrowCudaErrors(cudaMemcpyToSymbol(g_NumPhotonEmittedVolume2, &m_uPhotonEmittedPassVolume, sizeof(m_uPhotonEmittedPassVolume)));
	ThrowCudaErrors(cudaMemcpyToSymbol(g_VolEstimator2, m_pVolumeEstimator, m_pVolumeEstimator->getSize()));

	int fg_samples = m_sParameters.getValue(KEY_N_FG_Samples());
		
	k_AdaptiveStruct A = getAdaptiveData();
	Vec2i off = Vec2i(x, y);
	BlockSampleImage img = m_pBlockSampler->getBlockImage();
	
	iterateTypes<BeamGrid, PointStorage, BeamBeamGrid>(m_pVolumeEstimator, [off,&A,&img, fg_samples,this](auto* X) {CudaTracerLib::k_EyePass<std::remove_pointer<decltype(X)>::type> << <BLOCK_SAMPLER_LAUNCH_CONFIG >> >(off, this->w, this->h, A, img, this->m_useDirectLighting, fg_samples); });

	ThrowCudaErrors(cudaThreadSynchronize());
	m_pPixelBuffer->setOnGPU();
}

}

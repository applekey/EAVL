#include "eavlException.h"
#include "eavlExecutor.h"
#include "eavlSimpleVRMutator.h"
#include "eavlMapOp.h"
#include "eavlColor.h"
#include "eavlPrefixSumOp_1.h"
#include "eavlReduceOp_1.h"
#include "eavlGatherOp.h"
#include "eavlSimpleReverseIndexOp.h"
#include "eavlRayExecutionMode.h"
#include "eavlRTUtil.h"
#ifdef HAVE_CUDA
#include <cuda.h>
#include <cuda_runtime_api.h>
#endif

#define COLOR_MAP_SIZE 1024

long int scounter = 0;
long int skipped = 0;

texture<float4> scalars_tref;
texture<float4> cmap_tref;

eavlConstTexArray<float4>* color_map_array;
eavlConstTexArray<float4>* scalars_array;

#define PASS_ESTIMATE_FACTOR  2.5f

//-------------------------------------------------

eavlSimpleVRMutator::eavlSimpleVRMutator()
{   
    cpu = eavlRayExecutionMode::isCPUOnly();


    opacityFactor = 1.f;
    height = 100;
    width  = 100;    
    setNumPasses(1); //default number of passes
    samples                = NULL;
    framebuffer            = NULL;
    zBuffer                = NULL;
    minSample              = NULL;
    iterator               = NULL;
    screenIterator         = NULL;
    colormap_raw           = NULL;
    minPasses              = NULL;
    maxPasses              = NULL;
    currentPassMembers     = NULL;
    passNumDirty           = true;
    indexScan              = NULL;
    reverseIndex           = NULL;
    scalars_array          = NULL; 

    ir = new eavlArrayIndexer(4,0);
    ig = new eavlArrayIndexer(4,1);
    ib = new eavlArrayIndexer(4,2);
    ia = new eavlArrayIndexer(4,3);
    ssa    = NULL;
    ssb    = NULL;
    ssc    = NULL;
    ssd    = NULL;
    tetSOA = NULL;
    mask   = NULL;
    rgba   = NULL;
    scene = new eavlVRScene();

    geomDirty = true;
    sizeDirty = true;

    numTets = 0;
    nSamples = 500;
    passCount = new eavlIntArray("",1,1); 
    i1 = new eavlArrayIndexer(3,0);
    i2 = new eavlArrayIndexer(3,1);
    i3 = new eavlArrayIndexer(3,2);
    idummy = new eavlArrayIndexer();
    idummy->mod = 1 ;
    dummy = new eavlFloatArray("",1,2);

    verbose = false;

    setDefaultColorMap(); 
    isTransparentBG = false;
    
    //
    // Init sample buffer
    // 
    dx = width;
    dy = height;
    dz = nSamples;
    xmin = 0;
    ymin = 0;
    zmin = 0;  
}

//-------------------------------------------------

eavlSimpleVRMutator::~eavlSimpleVRMutator()
{
    if(verbose) cout<<"Destructor"<<endl;
    deleteClassPtr(samples);
    deleteClassPtr(framebuffer);
    deleteClassPtr(zBuffer);
    deleteClassPtr(minSample);
    deleteClassPtr(rgba);
    deleteClassPtr(scene);
    deleteClassPtr(ssa);
    deleteClassPtr(ssb);
    deleteClassPtr(ssc);
    deleteClassPtr(ssd);
    deleteClassPtr(iterator);
    deleteClassPtr(i1);
    deleteClassPtr(i2);
    deleteClassPtr(i3);
    deleteClassPtr(ir);
    deleteClassPtr(ig);
    deleteClassPtr(ib);
    deleteClassPtr(ia);
    deleteClassPtr(idummy);
    deleteClassPtr(minPasses);
    deleteClassPtr(maxPasses);
    deleteClassPtr(indexScan);
    deleteClassPtr(mask);
    deleteClassPtr(dummy);
    deleteClassPtr(currentPassMembers);
    deleteClassPtr(reverseIndex);
    deleteClassPtr(screenIterator);

    freeTextures();
    freeRaw();

}

//-------------------------------------------------

void eavlSimpleVRMutator::getBBoxPixelExtent(eavlPoint3 &smins, eavlPoint3 &smaxs)
{
    float xmin = FLT_MAX;
    float xmax = -FLT_MAX;
    float ymin = FLT_MAX;
    float ymax = -FLT_MAX;
    float zmin = FLT_MAX;
    float zmax = -FLT_MAX;

    eavlPoint3 bbox[2];
    bbox[0] = smins;
    bbox[1] = smaxs;
    for(int x = 0; x < 2 ; x++)
    {
        for(int y = 0; y < 2 ; y++)
        {
            for(int z = 0; z < 2 ; z++)
            {
                eavlPoint3 temp(bbox[x].x, bbox[y].y, bbox[z].z);

                eavlPoint3 t = view.P * view.V * temp;
                t.x = (t.x*.5+.5)  * view.w;
                t.y = (t.y*.5+.5)  * view.h;
                t.z = (t.z*.5+.5)  * (float) nSamples;
                zmin = min(zmin,t.z);
                ymin = min(ymin,t.y);
                xmin = min(xmin,t.x);
                zmax = max(zmax,t.z);
                ymax = max(ymax,t.y);
                xmax = max(xmax,t.x);
            }
        }
    }
  
  
    xmin-=.001f;
    xmax+=.001f;
    ymin-=.001f;
    ymax+=.001f;
    zmin+=.001f;
    xmin = floor(fminf(fmaxf(0.f, xmin),view.w));
    xmax = ceil(fminf(fmaxf(0.f, xmax),view.w));
    ymin = floor(fminf(fmaxf(0.f, ymin),view.h));
    ymax = ceil(fminf(fmaxf(0.f, ymax),view.h));
    zmin = floor(fminf(fmaxf(0.f, zmin),nSamples));
    zmax = ceil(fminf(fmaxf(0.f, zmax),nSamples));
    smins.x = xmin;
    smins.y = ymin;
    smins.z = zmin;

    smaxs.x = xmax;
    smaxs.y = ymax;
    smaxs.z = zmax;
    //cout<<"BBOX "<<smins<<smaxs<<endl;
}

//-------------------------------------------------

//
//  TODO: This is no longer technically screen space. All coordinates
//        are offset into "sample space" which is a subset of screen space.
//
struct ScreenSpaceFunctor
{   
    float4 *xverts;
    float4 *yverts; 
    float4 *zverts;
    eavlView         view;
    int              nSamples;
    float            xmin;
    float            ymin;
    float            zmin;
    ScreenSpaceFunctor(float4 *_xverts, float4 *_yverts,float4 *_zverts, eavlView _view, int _nSamples, int _xmin, int _ymin, int _zmin)
    : view(_view), xverts(_xverts),yverts(_yverts),zverts(_zverts), nSamples(_nSamples), xmin(_xmin), ymin(_ymin), zmin(_zmin)
    {}

    EAVL_FUNCTOR tuple<float,float,float,float,float,float,float,float,float,float,float,float> operator()(tuple<int> iterator)
    {
        int tet = get<0>(iterator);
        eavlPoint3 mine(FLT_MAX,FLT_MAX,FLT_MAX);
        eavlPoint3 maxe(-FLT_MAX,-FLT_MAX,-FLT_MAX);

        float* v[3];
        v[0] = (float*)&xverts[tet]; //x
        v[1] = (float*)&yverts[tet]; //y
        v[2] = (float*)&zverts[tet]; //z

        eavlPoint3 p[4];
        //int clipped = 0;
        for( int i=0; i< 4; i++)
        {   
            p[i].x = v[0][i];
            p[i].y = v[1][i]; 
            p[i].z = v[2][i];

            eavlPoint3 t = view.P * view.V * p[i];
            //cout<<"Before"<<t<<endl;
            // if(t.x > 1 || t.x < -1) clipped = 1;
            // if(t.y > 1 || t.y < -1) clipped = 1;
            // if(t.z > 1 || t.z < -1) clipped = 1;
            p[i].x = (t.x*.5+.5)  * view.w -xmin;
            p[i].y = (t.y*.5+.5)  * view.h - ymin;
            p[i].z = (t.z*.5+.5)  * (float) nSamples -zmin;
            //cout<<"After "<<p[i]<<endl;
        }
        

        return tuple<float,float,float,float,float,float,float,float,float,float,float,float>(p[0].x, p[0].y, p[0].z,
                                                                                                  p[1].x, p[1].y, p[1].z,
                                                                                                  p[2].x, p[2].y, p[2].z,
                                                                                                  p[3].x, p[3].y, p[3].z);
    }

   

};

//-------------------------------------------------

struct PassRange
{   
    float4 *xverts;
    float4 *yverts;
    float4 *zverts;
    eavlView         view;
    int              nSamples; // this is now the number of samples that the inside image space
    float            mindepth;
    float            maxdepth;
    int              numPasses;
    int              passStride;
    int              CellThreshold;
    float            zmin;// need this to transate into "sample space"
    int              dz;
    int              mysampleLCFlag;

    PassRange(float4 *_xverts, float4 *_yverts,float4 *_zverts, eavlView _view, int _nSamples, int _numPasses, int _zmin, int _dz, int _sampleLCFlag)
    : view(_view), xverts(_xverts),yverts(_yverts),zverts(_zverts), nSamples(_nSamples), numPasses(_numPasses), zmin(_zmin), dz(_dz), mysampleLCFlag(_sampleLCFlag)
    {
        CellThreshold = 100;
        passStride = dz / numPasses;
        //if it is not evenly divided add one pixel row so we cover all pixels
        if(((int)nSamples % numPasses) != 0) passStride++;
        
    }

    EAVL_FUNCTOR tuple<byte,byte,int> operator()(tuple<int> iterator)
    {
        int tet = get<0>(iterator);
        eavlPoint3 mine(FLT_MAX,FLT_MAX,FLT_MAX);
        eavlPoint3 maxe(-FLT_MAX,-FLT_MAX,-FLT_MAX);
        float* v[3];
        v[0] = (float*)&xverts[tet]; //x
        v[1] = (float*)&yverts[tet]; //y
        v[2] = (float*)&zverts[tet]; //z

        int clipped = 0;
        eavlPoint3 p[4];

        for( int i=0; i < 4; i++)
        {   
            p[i].x = v[0][i];
            p[i].y = v[1][i]; 
            p[i].z = v[2][i];

            eavlPoint3 t = view.P * view.V * p[i];
            if(t.x > 1 || t.x < -1) clipped = 1;
            if(t.y > 1 || t.y < -1) clipped = 1;
            if(t.z > 1 || t.z < -1) clipped = 1;
            p[i].x = (t.x*.5+.5)  * view.w;
            p[i].y = (t.y*.5+.5)  * view.h;
            p[i].z = (t.z*.5+.5)  * (float) nSamples - zmin; //into sample space

        }
        //Looping over faces
        for(int i=0; i<4; i++)
        {    
            //looping over dimenstions
            for (int d=0; d<3; ++d)
            {
                    mine[d] = min(p[i][d], mine[d] );
                    maxe[d] = max(p[i][d], maxe[d] );
            }
        }
        //if the tet stradles the edge, dump it TODO: extra check to make sure it is all the way outside
        float mn = min(mine[2],min(mine[1],min(mine[0], float(1e9) )));
        if(mn < 0) clipped = 1;
        
        if(clipped == 1) return tuple<byte,byte,int>(255,255,0); //not part of any pass
        int minPass = 0;
        int maxPass = 0;
        // now transate into sample space
        minPass = mine[2] / passStride; //min z coord
        maxPass = maxe[2] / passStride; //max z coord

        int tetNumofSample = ((maxe[0] - mine[0]) * (maxe[0] - mine[0])) + ((maxe[1] - mine[1]) * (maxe[1] - mine[1])) + ((maxe[2] - mine[2]) * (maxe[2] - mine[2]));

    if(mysampleLCFlag == 0)
    { 
      if(tetNumofSample > CellThreshold)
       return tuple<byte,byte,int>(255,255,tetNumofSample);
      
       else
        return tuple<byte,byte,int>(minPass, maxPass,0);
    }// if sampleLCFlag == 0 which mean only sample small cells
    else
    {
        return tuple<byte,byte,int>(minPass, maxPass,0);
    }// sampleLCFlag == 1 which means sample large cells
    
    }
};

//-------------------------------------------------

float EAVL_HOSTDEVICE ffmin(const float &a, const float &b)
{
    #if __CUDA_ARCH__
        return fmin(a,b);
    #else
        return (a > b) ? b : a;
    #endif
}

//-------------------------------------------------

float EAVL_HOSTDEVICE ffmax(const float &a, const float &b)
{
     #if __CUDA_ARCH__
        return fmax(a,b);
    #else
        return (a > b) ? a : b;
    #endif
    
}

//-------------------------------------------------

//
// Incoming coordinate are in sample space
//
struct SampleFunctor3
{   
    const eavlConstTexArray<float4> *scalars;
    eavlView         view;
    int              nSamples;
    float*           samples;
    float*           fb;
    int              passMinZPixel;
    int              passMaxZPixel;
    int              zSize;
    int              dx;
    int              dy;
    int              dz;
    int              minx;
    int              miny;
    SampleFunctor3(const eavlConstTexArray<float4> *_scalars, eavlView _view, int _nSamples, float* _samples, int _passMinZPixel, int _passMaxZPixel,int numZperPass, float* _fb, int _dx, int _dy, int _dz, int _minx, int _miny)
    : view(_view), scalars(_scalars), nSamples(_nSamples), samples(_samples), dx(_dx), dy(_dy), dz(_dz), minx(_minx), miny(_miny)
    {
        
        passMaxZPixel  = min(int(dz-1), _passMaxZPixel);
        passMinZPixel  = max(0, _passMinZPixel);
        zSize = numZperPass;
        fb = _fb;
        //printf("Min and max z pixel : %d %d \n", passMinZPixel, passMaxZPixel);
    }

    EAVL_FUNCTOR tuple<float> operator()(tuple<int,float,float,float,float,float,float,float,float,float,float,float,float> inputs )
    {
        int tet = get<0>(inputs);
        
        eavlVector3 p[4]; //TODO vectorize
        p[0].x = get<1>(inputs);
        p[0].y = get<2>(inputs);
        p[0].z = get<3>(inputs);

        p[1].x = get<4>(inputs);
        p[1].y = get<5>(inputs);
        p[1].z = get<6>(inputs);

        p[2].x = get<7>(inputs);
        p[2].y = get<8>(inputs);
        p[2].z = get<9>(inputs);

        p[3].x = get<10>(inputs);
        p[3].y = get<11>(inputs);
        p[3].z = get<12>(inputs);

        eavlVector3 v[3];
        for(int i = 1; i < 4; i++)
        {
            v[i-1] = p[i] - p[0];
        }

        //                  a         b            c       d
        //float d1 = D22(mat[1][1], mat[1][2], mat[2][1], mat[2][2]);
        float d1 = v[1].y * v[2].z - v[2].y * v[1].z;
        //float d2 = D22(mat[1][0], mat[1][2], mat[2][0], mat[2][2]);
        float d2 = v[0].y * v[2].z - v[2].y *  v[0].z;
        //float d3 = D22(mat[1][0], mat[1][1], mat[2][0], mat[2][1]);
        float d3 = v[0].y * v[1].z - v[1].y * v[0].z;

        float det = v[0].x * d1 - v[1].x * d2 + v[2].x * d3;

        if(det == 0) return tuple<float>(0.f); // dirty degenerate tetrahedron
        det  = 1.f  / det;

        //D22(mat[0][1], mat[0][2], mat[2][1], mat[2][2]);
        float d4 = v[1].x * v[2].z - v[2].x * v[1].z;
        //D22(mat[0][1], mat[0][2], mat[1][1], mat[1][2])
        float d5 = v[1].x * v[2].y - v[2].x * v[1].y;
        //D22(mat[0][0], mat[0][2], mat[2][0], mat[2][2]) 
        float d6 = v[0].x * v[2].z- v[2].x * v[0].z; 
        //D22(mat[0][0], mat[0][2], mat[1][0], mat[1][2])
        float d7 = v[0].x * v[2].y - v[2].x * v[0].y;
        //D22(mat[0][0], mat[0][1], mat[2][0], mat[2][1])
        float d8 = v[0].x * v[1].z - v[1].x * v[0].z;
        //D22(mat[0][0], mat[0][1], mat[1][0], mat[1][1])
        float d9 = v[0].x * v[1].y - v[1].x * v[0].y;
        /* need the extents again, just recalc */
        eavlPoint3 mine(FLT_MAX,FLT_MAX,FLT_MAX);
        eavlPoint3 maxe(-FLT_MAX,-FLT_MAX,-FLT_MAX);
       
        for(int i=0; i<4; i++)  //these two loops cost 2 registers
        {    
            for (int d=0; d<3; ++d) 
            {
                    mine[d] = min(p[i][d], mine[d] );
                    maxe[d] = max(p[i][d], maxe[d] );
            }
        } 

        // for(int i = 0; i < 3; i++) mine[i] = max(mine[i],0.f);
        // /*clamp*/
        maxe[0] = min(float(dx-1.f), maxe[0]); //??  //these lines cost 14 registers
        maxe[1] = min(float(dy - 1.f), maxe[1]);
        maxe[2] = min(float(passMaxZPixel), maxe[2]);
        mine[2] = max(float(passMinZPixel), mine[2]);
        //cout<<p[0]<<p[1]<<p[2]<<p[3]<<endl;
        int xmin = ceil(mine[0]);
        int xmax = floor(maxe[0]);
        int ymin = ceil(mine[1]);
        int ymax = floor(maxe[1]);
        int zmin = ceil(mine[2]);
        int zmax = floor(maxe[2]);

        float4 s = scalars->getValue(scalars_tref, tet);
        //cerr<<" X "<<xmin<<" to "<<xmax<<"\n";
        //cerr<<" Y "<<ymin<<" to "<<ymax<<"\n";
        for(int x = xmin; x <= xmax; ++x)
        {
            for(int y = ymin; y <= ymax; ++y)
            { 
                int pixel = ( (y+miny) * view.w + x + minx);
                if(fb[pixel * 4 + 3] >= 1) {continue;} //TODO turn this on using sample space to screen space
                
                int startindex = (y * dx + x) * zSize;//dx*(y + dy*(z -passMinZPixel));
                #pragma ivdep
                for(int z=zmin; z<=zmax; ++z)
                {

                    float w1 = x - p[0].x; 
                    float w2 = y - p[0].y; 
                    float w3 = z - p[0].z; 

                    float xx =   w1 * d1 - w2 * d4 + w3 * d5;
                    xx *= det; 

                    float yy = - w1 * d2 + w2 * d6 - w3 * d7; 
                    yy *= det;

                    float zz =   w1 * d3 - w2 * d8 + w3 * d9;
                    zz *= det;
                    w1 = xx; 
                    w2 = yy; 
                    w3 = zz; 

                    float w0 = 1.f - w1 - w2 - w3;

                    int index3d = startindex + z;
                    float lerped = w0*s.x + w1*s.y + w2*s.z + w3*s.w;
                    float a = ffmin(w0,ffmin(w1,ffmin(w2,w3)));
                    float b = ffmax(w0,ffmax(w1,ffmax(w2,w3)));
                    if((a >= 0.f && b <= 1.f)) 
                    {
                        samples[index3d] = lerped;
                       if(x == 359 && y == 282)
                        cerr<<"Cell "<<tet<<"\n";
                        //cerr<<"Z "<<z<<" value "<<samples[index3d]<<"\n";
                      // cerr<<"HEEEEEELLO\n";
                        //if(lerped < 0 || lerped >1) printf("Bad lerp %f ",lerped);
                    }
                     
                   

                }//z
            }//y                                                                                                                                                                                           
        }//x

        return tuple<float>(0.f);
    }
};

//-------------------------------------------------

struct CompositeFunctorFB
{   
    const eavlConstTexArray<float4> *colorMap;
    eavlView         view;
    int              nSamples;
    float*           samples;
    int              h;
    int              w;
    int              ncolors;
    float            mindepth;
    float            maxdepth;
    eavlPoint3       minComposite;
    eavlPoint3       maxComposite;
    int              zOffest;
    bool             finalPass;
    int              maxSIndx;
    int              minZPixel;

    int              dx;
    int              dy;
    //int              dz;
    int              xmin;
    int              ymin;

    CompositeFunctorFB( eavlView _view, int _nSamples, float* _samples, const eavlConstTexArray<float4> *_colorMap, int _ncolors, eavlPoint3 _minComposite, eavlPoint3 _maxComposite, int _zOffset, bool _finalPass, int _maxSIndx, int _minZPixel, int _dx, int _dy, int _xmin, int _ymin)
    : view(_view), nSamples(_nSamples), samples(_samples), colorMap(_colorMap), ncolors(_ncolors), minComposite(_minComposite), maxComposite(_maxComposite), finalPass(_finalPass), maxSIndx(_maxSIndx),
      dx(_dx), dy(_dy), xmin(_xmin), ymin(_ymin)
    {
        w = view.w;
        h = view.h;
        zOffest = _zOffset;
        minZPixel = _minZPixel;
    }
 
    EAVL_FUNCTOR tuple<float,float,float,float,int> operator()(tuple<int, float, float, float, float, int> inputs )
    {
        int idx = get<0>(inputs);
        int x = idx%w;
        int y = idx/w;
        int minZsample = get<5>(inputs);
        //get the incoming color and return if the opacity is already 100%
        float4 color= {get<1>(inputs),get<2>(inputs),get<3>(inputs),get<4>(inputs)};
        if(color.w >= 1) return tuple<float,float,float,float,int>(color.x, color.y, color.z,color.w, minZsample);
        //cerr<<"Before \n";
        x-= xmin;
        y-= ymin;
        //pixel outside the AABB of the data set
        if((x >= dx) || (x < 0) || ( y >= dy) || (y < 0))
        {
            return tuple<float,float,float,float,int>(0.f,0.f,0.f,0.f, minZsample);
        }
        //cerr<<"After is \n";
        for(int z = 0 ; z < zOffest; z++)
        {
                //(x + view.w*(y + zSize*z));
            int index3d = (y*dx + x)*zOffest + z;//(x + dx*(y + dy*(z))) ;//
            
            //printf("Coord = (%f,%f,%f) %d ",x,y,z, index3d);
            float value =  samples[index3d];//tsamples->getValue(samples_tref, index3d);// samples[index3d];
            
            //takes init value -1 if it was a large cell 
            if (value <= 0.f || value > 1.f)
                continue; //cerr<<"Value "<<value<<"\n";
        
            int colorindex = float(ncolors-1) * value;
            float4 c = colorMap->getValue(cmap_tref, colorindex);
            //cout<<"color for value "<<value<<" is "<<color.x<<" "<<color.y<<" "<<color.z<<" "<<color.w<<"\n";
            c.w *= (1.f - color.w); 
            color.x = color.x  + c.x * c.w;
            color.y = color.y  + c.y * c.w;
            color.z = color.z  + c.z * c.w;
            color.w = c.w + color.w;

                  minZsample = min(minZsample, minZPixel + z); //we need the closest sample to get depth buffer 
            if(color.w >=1 ) break;

        }
   	
//	cerr<<"Min Sample "<<minZsample<<"\n"; 
        return tuple<float,float,float,float,int>(min(1.f, color.x),  min(1.f, color.y),min(1.f, color.z),min(1.f,color.w), minZsample);
        
    }
   

};
//-------------------------------------------------
/*
struct PartialComposite
{

public:
    int startIndex;
    int endIndex;
    int x;
    int y;
    float4 color;

};
/*
struct PixelPartials
{
public:
    int numOfPartials;
    PartialComposite* myPartialsArray;

};*/
//typedef eavlConcreteArray<PartialComposite> eavlPartialComp;
//-------------------------------------------------

struct TestMyStruct
{
    int factor;
    float* ray;
    eavlIntArray* offesetPartials;

    TestMyStruct(float* _rays,eavlIntArray* _offesetPartials):ray(_rays), offesetPartials(_offesetPartials)
    {
        factor = 2;
    }
    EAVL_FUNCTOR tuple<float> operator()(tuple<int> inputs)
    {
        ray[0] = 45.0;

        //ray.x = ray.x * factor;
        //ray.y = ray.y * factor;


        return tuple<float>(0.f);
    }

};
//-------------------------------------------------
/*
float4 ApplyTF(float* samples, int numSamples,const eavlConstTexArray<float4> *colorMap, int ncolors)
{
    float4 color= {0.0,0.0,0.0,0.0};

    for(int i=0;i < numSamples; i++)
    {
        int colorindex = float(ncolors-1) * samples[i];
        float4 c = colorMap->getValue(cmap_tref, colorindex);
        c.w *= (1.f - color.w); 
        color.x = color.x  + c.x * c.w;
        color.y = color.y  + c.y * c.w;
        color.z = color.z  + c.z * c.w;
        color.w = c.w + color.w;

        if(color.w >= 0.99)return color;
    }

    return color;
}*/
//-------------------------------------------------
struct GetPartialComposites
{   
    const eavlConstTexArray<float4> *colorMap;
    eavlView         view;
    int              nSamples;
    float*           samples;
    int              h;
    int              w;
    int              ncolors;
    float            mindepth;
    float            maxdepth;
    eavlPoint3       minComposite;
    eavlPoint3       maxComposite;
    int              zOffest;
    bool             finalPass;
    int              maxSIndx;
    int              minZPixel;

    int              dx;
    int              dy;
    //int              dz;
    int              xmin;
    int              ymin;
    eavlIntArray*             numOfPartials;
    eavlIntArray* offesetPartials;
    //int start;
    float* rays;
    //int index;
    //int origX, origY;

    GetPartialComposites( eavlView _view, int _nSamples, float* _samples,float* _rays, eavlIntArray* _offesetPartials, const eavlConstTexArray<float4> *_colorMap, int _ncolors, eavlPoint3 _minComposite, eavlPoint3 _maxComposite, int _zOffset, bool _finalPass, int _maxSIndx, int _minZPixel, int _dx, int _dy, int _xmin, int _ymin, eavlIntArray* _numOfPartials)
    : view(_view), nSamples(_nSamples), samples(_samples),rays(_rays), offesetPartials(_offesetPartials), colorMap(_colorMap), ncolors(_ncolors), minComposite(_minComposite), maxComposite(_maxComposite), finalPass(_finalPass), maxSIndx(_maxSIndx),
      dx(_dx), dy(_dy), xmin(_xmin), ymin(_ymin), numOfPartials(_numOfPartials)
    {
        w = view.w;
        h = view.h;
        zOffest = _zOffset;
        minZPixel = _minZPixel;
        

    }
 
    EAVL_FUNCTOR tuple<float> operator()(tuple<int,int> inputs )
    {
        int idx = get<0>(inputs);
        int x = idx%w;
        int y = idx/w;
        int origX = x;
        int origY = y;
        int minZsample = get<1>(inputs);
        int start = 0;
        int end =0;
        int partInd = 0;
        int index=0;
        //get the incoming color and return if the opacity is already 100%
        float4 color= {0.0,0.0,0.0,0.0};
        float4 pc = {0.0,0.0,0.0,0.0};
       // if(color.w >= 1) return tuple<float>(0.0);
        //cerr<<"Before \n";
        x-= xmin;
        y-= ymin;
        //pixel outside the AABB of the data set
        if((x >= dx) || (x < 0) || ( y >= dy) || (y < 0) || numOfPartials == 0)
        {
            return  tuple<float>(0.f);//tuple<float,float,float,float,int>(0.f,0.f,0.f,0.f, minZsample);
        }
        //cerr<<"After is \n";
        for(int z = 0 ; z < zOffest; z++)
        {
                //(x + view.w*(y + zSize*z));
            int index3d = (y*dx + x)*zOffest + z;//(x + dx*(y + dy*(z))) ;//
            int myOffest = offesetPartials->GetValue(idx);
            //if(idx == 0)
            //cerr<<" pixel "<<idx<<" myOffest is "<<myOffest<<"\n";
            //cerr<<"3D index "<<index3d<<" index "<<idx<<"\n";
            //printf("Coord = (%f,%f,%f) %d ",x,y,z, index3d);
            float value =  samples[index3d];//tsamples->getValue(samples_tref, index3d);// samples[index3d];
            
            //takes init value -1 if it was a large cell 
            //if (value <= 0.f || value > 1.f)
            //    continue; //cerr<<"Value "<<value<<"\n";
            if( value  > 0.0f)
                {  
                    if(start ==0)
                    {
                        index = myOffest*8+partInd*8;
                        
                        //rays[index+0] = idx;
                        rays[index+0] = origX;
                        rays[index+1] = origY;
                        rays[index+2] = z;
                        start = 1;
                    } //if start = 0
                    int colorindex = float(ncolors-1) * value;
                    float4 c = colorMap->getValue(cmap_tref, colorindex);
                    //cout<<"color for value "<<value<<" is "<<color.x<<" "<<color.y<<" "<<color.z<<" "<<color.w<<"\n";
                    //if(color.w < 0.95 )
                   //{c.w *= (1.f - color.w); 
                    color.x = c.x;
                    color.y = c.y;
                    color.z = c.z;
                    color.w = c.w;

                    if(pc.w< 1)
                    {
                        //c.w *= (1.f - pc.w); 
                        pc.x = pc.x  + (1-pc.w) *c.x * c.w;
                        pc.y = pc.y  + (1-pc.w) *c.y * c.w;
                        pc.z = pc.z  + (1-pc.w) *c.z * c.w;
                        pc.w = pc.w  + (1-pc.w) *c.w;

                        
                    }//pc.w < 0.95

                }// if (value >=0 )
                
            if(value < 0.0f && start == 1)
               { start = 0;
                 end = 1;
                 rays[index+3] = z-1;
                 /*
                 rays[index+4] = color.x;
                 rays[index+5] = color.y;
                 rays[index+6] = color.z;
                 rays[index+7] = color.w;*/
                 partInd++;
                //add color to arrray as partial composite
               }
               if(value >=0 && z == zOffest-1)
               {
                 start = 0;
                 end = 1;
                 rays[index+3] = z;
                 /*
                 rays[index+4] = color.x;
                 rays[index+5] = color.y;
                 rays[index+6] = color.z;
                 rays[index+7] = color.w;*/
                 partInd++;
               }

             //  if(end == 1)
               //{
                 rays[index+4] = pc.x;
                 rays[index+5] = pc.y;
                 rays[index+6] = pc.z;
                 rays[index+7] = pc.w;
                 end = 0;
                 /*
               if(rays[index+2] == rays[index+3])
               {
                 
                 //rays[index+4] = color.x;
                 //rays[index+5] = color.y;
                 //rays[index+6] = color.z;
                 //rays[index+7] = color.w;
                 rays[index+4] = pc.x;
                 rays[index+5] = pc.y;
                 rays[index+6] = pc.z;
                 rays[index+7] = pc.w;
                 end = 0;
               }
               
               else
               {
                //float4 pc = ApplyTF(partialsFloat, numOfsampperPart,colorMap,ncolors);
                 rays[index+4] = pc.x;
                 rays[index+5] = pc.y;
                 rays[index+6] = pc.z;
                 rays[index+7] = pc.w;
                 end = 0;
               }*/

             // }//if end ==1


               //if(origX == 0 && origY == 0)
                //cerr<<"Pixel 0 0 has "<<partInd<<"\n";
               /*
            int colorindex = float(ncolors-1) * value;
            float4 c = colorMap->getValue(cmap_tref, colorindex);
            //cout<<"color for value "<<value<<" is "<<color.x<<" "<<color.y<<" "<<color.z<<" "<<color.w<<"\n";
            c.w *= (1.f - color.w); 
            color.x = color.x  + c.x * c.w;
            color.y = color.y  + c.y * c.w;
            color.z = color.z  + c.z * c.w;
            color.w = c.w + color.w;

                  minZsample = min(minZsample, minZPixel + z); //we need the closest sample to get depth buffer 
            if(color.w >=1 ) break;*/

       }// for Z
        //cerr<<"Color "<<color.x<<" "<<color.y<<" "<<color.z<<" "<<color.w<<"\n";
//  cerr<<"Min Sample "<<minZsample<<"\n"; 
        //return tuple<float,float,float,float,int>(min(1.f, color.x),  min(1.f, color.y),min(1.f, color.z),min(1.f,color.w), minZsample);
     return tuple<float>(0.f);  
    }
};

//-------------------------------------------------
struct GetNumOfPartialCompNum
{   
    const eavlConstTexArray<float4> *colorMap;
    eavlView         view;
    int              nSamples;
    float*           samples;
    int              h;
    int              w;
    int              ncolors;
    float            mindepth;
    float            maxdepth;
    eavlPoint3       minComposite;
    eavlPoint3       maxComposite;
    int              zOffest;
    bool             finalPass;
    int              maxSIndx;
    int                    minZPixel;

    int              dx;
    int              dy;
    //int              dz;
    int              xmin;
    int              ymin;
    //int              start;
    GetNumOfPartialCompNum( eavlView _view, int _nSamples, float* _samples, const eavlConstTexArray<float4> *_colorMap, int _ncolors, eavlPoint3 _minComposite, eavlPoint3 _maxComposite, int _zOffset, bool _finalPass, int _maxSIndx, int _minZPixel, int _dx, int _dy, int _xmin, int _ymin)
    : view(_view), nSamples(_nSamples), samples(_samples), colorMap(_colorMap), ncolors(_ncolors), minComposite(_minComposite), maxComposite(_maxComposite), finalPass(_finalPass), maxSIndx(_maxSIndx),
      dx(_dx), dy(_dy), xmin(_xmin), ymin(_ymin)
    {
        w = view.w;
        h = view.h;
        zOffest = _zOffset;
        minZPixel = _minZPixel;
        
    }
 
    EAVL_FUNCTOR tuple<int> operator()(tuple< int> inputs )
    {
        int idx = get<0>(inputs);
        int x = idx%w;
        int y = idx/w;
        int numOfPartials = 0;
        int start = 0;
        //get the incoming color and return if the opacity is already 100%
        //cerr<<"Before \n";
        x-= xmin;
        y-= ymin;
        //pixel outside the AABB of the data set
        if((x >= dx) || (x < 0) || ( y >= dy) || (y < 0))
        {
            return tuple<int>(0);
        }
        //cerr<<"After is \n";
        for(int z = 0 ; z < zOffest; z++)
        {
                //(x + view.w*(y + zSize*z));
            int index3d = (y*dx + x)*zOffest + z;//(x + dx*(y + dy*(z))) ;//
            
            //printf("Coord = (%f,%f,%f) %d ",x,y,z, index3d);
            float value =  samples[index3d];//tsamples->getValue(samples_tref, index3d);// samples[index3d];
            
            //takes init value -1 if it was a large cell 
           // if (value <= 0.f || value > 1.f)
              //  continue; //cerr<<"Value "<<value<<"\n";
          //  if(value < 0)
            //cerr<<"Value "<<value<<" at z "<<z<<"\n";


            if( value  >= 0.0f  && start == 0)
                {  
                    start = 1;
                    numOfPartials++;
                    
                }
            if(value < 0.0f && start == 1)
                start = 0;
        
            /*
            int colorindex = float(ncolors-1) * value;
            float4 c = colorMap->getValue(cmap_tref, colorindex);
            //cout<<"color for value "<<value<<" is "<<color.x<<" "<<color.y<<" "<<color.z<<" "<<color.w<<"\n";
            c.w *= (1.f - color.w); 
            color.x = color.x  + c.x * c.w;
            color.y = color.y  + c.y * c.w;
            color.z = color.z  + c.z * c.w;
            color.w = c.w + color.w;

                  minZsample = min(minZsample, minZPixel + z); //we need the closest sample to get depth buffer 
            if(color.w >=1 ) break;*/
       }
    
       //cerr<<"Num of partials in this pixel is "<<numOfPartials<<"\n";
//  cerr<<"Min Sample "<<minZsample<<"\n"; 
        return tuple<int>(numOfPartials);
        
    }
};

//-------------------------------------------------

//compisite the bakground color into the framebuffer
struct CompositeBG
{   
    float4 cc;
    CompositeBG(eavlColor &_bgColor)
    {
        cc.x = _bgColor.c[0];
        cc.y = _bgColor.c[1];
        cc.z = _bgColor.c[2];
        cc.w = _bgColor.c[3]; 
        
        
    }

    EAVL_FUNCTOR tuple<float,float,float,float> operator()(tuple<float, float, float, float> inputs )
    {

        float4 color= {get<0>(inputs),get<1>(inputs),get<2>(inputs),get<3>(inputs)};
        if(color.w >= 1) return tuple<float,float,float,float>(color.x, color.y, color.z,color.w);

        float4 c = cc; 
        
        c.w *= (1.f - color.w); 
        color.x = color.x  + c.x * c.w;
        color.y = color.y  + c.y * c.w;
        color.z = color.z  + c.z * c.w;
        color.w = c.w + color.w;

        return tuple<float,float,float,float>(min(1.f, color.x),  min(1.f, color.y),min(1.f, color.z),min(1.f,color.w) );
    }
};

//-------------------------------------------------

eavlFloatArray* eavlSimpleVRMutator::getDepthBuffer(float proj22, float proj23, float proj32)
{ 

        eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(minSample), eavlOpArgs(zBuffer), convertDepthFunctor(view,nSamples)),"convertDepth");
        eavlExecutor::Go();
        return zBuffer;
}

//-------------------------------------------------

void eavlSimpleVRMutator::setColorMap3f(float* cmap,int size)
{
    if(verbose) cout<<"Setting new color map 3f"<<endl;
    colormapSize = size;
    if(color_map_array != NULL)
    {
        color_map_array->unbind(cmap_tref);
        
        delete color_map_array;
    
        color_map_array = NULL;
    }
    if(colormap_raw != NULL)
    {
        delete[] colormap_raw;
        colormap_raw = NULL;
    }
    colormap_raw= new float[size*4];
    
    for(int i=0;i<size;i++)
    {
        colormap_raw[i*4  ] = cmap[i*3  ];
        colormap_raw[i*4+1] = cmap[i*3+1];
        colormap_raw[i*4+2] = cmap[i*3+2];
        colormap_raw[i*4+3] = .01f;          //test Alpha
    }
    color_map_array = new eavlConstTexArray<float4>((float4*)colormap_raw, colormapSize, cmap_tref, cpu);
}

//-------------------------------------------------

void eavlSimpleVRMutator::setColorMap4f(float* cmap,int size)
{
    if(verbose) cout<<"Setting new color map of size "<<size<<endl;
    colormapSize = size;
    if(color_map_array != NULL)
    {
        color_map_array->unbind(cmap_tref);
        
        delete color_map_array;
    
        color_map_array = NULL;
    }
    if(colormap_raw != NULL)
    {
        delete[] colormap_raw;
        colormap_raw = NULL;
    }
    colormap_raw= new float[size*4];
    
    for(int i=0;i<size;i++)
    {
        colormap_raw[i*4  ] = cmap[i*4  ];
        colormap_raw[i*4+1] = cmap[i*4+1];
        colormap_raw[i*4+2] = cmap[i*4+2];
        colormap_raw[i*4+3] = cmap[i*4+3];  
        //cout<<"Color "<<colormap_raw[i*4  ]<<" "<<colormap_raw[i*4 +1]<<" "<<colormap_raw[i*4 +2]<<" "<<colormap_raw[i*4 +3]<<endl;        
    }
    color_map_array = new eavlConstTexArray<float4>((float4*)colormap_raw, colormapSize, cmap_tref, cpu);
}

//-------------------------------------------------

void eavlSimpleVRMutator::setDefaultColorMap()
{   if(verbose) cout<<"setting defaul color map"<<endl;
    if(color_map_array!=NULL)
    {
        color_map_array->unbind(cmap_tref);
        delete color_map_array;
        color_map_array = NULL;
    }
    if(colormap_raw!=NULL)
    {
        delete[] colormap_raw;
        colormap_raw = NULL;
    }
    //two values all 1s
    colormapSize=2;
    colormap_raw= new float[8];
    for(int i=0;i<8;i++) colormap_raw[i]=1.f;
    color_map_array = new eavlConstTexArray<float4>((float4*)colormap_raw, colormapSize, cmap_tref, cpu);
    if(verbose) cout<<"Done setting defaul color map"<<endl;

}

//-------------------------------------------------

void eavlSimpleVRMutator::calcMemoryRequirements()
{

    unsigned long int mem = 0; //mem in bytes

    mem += pixelsPerPass * sizeof(float);       //samples
    mem += numTets * 12 * sizeof(float);
    mem += height * width * 4 * sizeof(float);  //framebuffer
    mem += height * width * sizeof(float);      //zbuffer
    mem += numTets * 4 * sizeof(float);         //scalars
    mem += numTets * 2;                         //min and max passes (BYTEs)
    mem += numTets * sizeof(int);               //interator
    mem += height * width * sizeof(int);        //screen iterator;
    mem += passCountEstimate * 12 * sizeof(float);//screen space coords
    //find pass members arrays
    mem += numTets * 4 * sizeof(int);           //indexscan, mask, currentPassMembers
    mem += passCountEstimate * sizeof(int);     //reverse index
    double memd = (double) mem / (1024.0 * 1024.0);
    if(verbose) printf("Memory needed %10.3f MB. Do you have enough?\n", memd);
    
    if(!cpu)
    {

#ifdef HAVE_CUDA
        size_t free_byte;
        size_t total_byte;
        cudaMemGetInfo( &free_byte, &total_byte );
        double free_db = (double)free_byte ;
        double total_db = (double)total_byte ;
        double used_db = total_db - free_db ;
        if(verbose) printf("GPU memory usage: used = %f, free = %f MB, total = %f MB\n", used_db/1024.0/1024.0, free_db/1024.0/1024.0, total_db/1024.0/1024.0);
        if(mem > free_byte)
        {
            cout<<"Warning : this will exceed memory usage by "<< (mem - free_byte) << "bytes.\n";
        }
#endif

    }   
}

//-------------------------------------------------

void printGPUMemUsage()
{
    #ifdef HAVE_CUDA
        size_t free_byte;
        size_t total_byte;
        cudaMemGetInfo( &free_byte, &total_byte );
        double free_db = (double)free_byte ;
        double total_db = (double)total_byte ;
        double used_db = total_db - free_db ;
        printf("GPU memory usage: used = %f, free = %f MB, total = %f MB\n", used_db/1024.0/1024.0, free_db/1024.0/1024.0, total_db/1024.0/1024.0);
#endif
}

//-------------------------------------------------

void eavlSimpleVRMutator::clearSamplesArray()
{
    //cerr<<"In function clearSamplesArray\n";
    int clearValue = 0xbf800000; //-1 float
    size_t bytes = pixelsPerPass * sizeof(float);
    if(!cpu)
    {
#ifdef HAVE_CUDA
       cudaMemset(samples->GetCUDAArray(), clearValue,bytes);
       CUDA_CHECK_ERROR();
#endif
    }
    else
    {
       memset(samples->GetHostArray(), clearValue, bytes);   
    }


}

//-------------------------------------------------

void eavlSimpleVRMutator::init()
{
    
    if(sizeDirty)
    {   
        setNumPasses(numPasses);
        if(verbose) cout<<"Size Dirty"<<endl;
       
        deleteClassPtr(samples);
        deleteClassPtr(framebuffer);
        deleteClassPtr(zBuffer);
        deleteClassPtr(minSample);
        
        samples         = new eavlFloatArray("",1,pixelsPerPass);
        framebuffer     = new eavlFloatArray("",1,height*width*4);
        rgba            = new eavlByteArray("",1,height*width*4);
        zBuffer         = new eavlFloatArray("",1,height*width);
        minSample       = new eavlIntArray("",1,height*width);
        clearSamplesArray();
        if(verbose) cout<<"Samples array size "<<pixelsPerPass<<" Current CPU val "<<cpu<< endl;
        if(verbose) cout<<"Current framebuffer size "<<(height*width*4)<<endl;
        sizeDirty = false;
         
    }

    if(geomDirty && numTets > 0)
    {   
        if(verbose) cout<<"Geometry Dirty"<<endl;
        firstPass = true;
        passNumDirty = true;
        freeTextures();
        freeRaw();

        deleteClassPtr(minPasses);
        deleteClassPtr(maxPasses);
        deleteClassPtr(iterator);
        deleteClassPtr(dummy);
        deleteClassPtr(indexScan);
        deleteClassPtr(mask);

        tetSOA = scene->getEavlTetPtrs();
        
        scalars_array       = new eavlConstTexArray<float4>( (float4*) scene->getScalarPtr()->GetHostArray(), 
                                                             numTets, 
                                                             scalars_tref, 
                                                             cpu);
        minPasses = new eavlByteArray("",1, numTets);
        maxPasses = new eavlByteArray("",1, numTets);
        indexScan = new eavlIntArray("",1, numTets);
        mask = new eavlIntArray("",1, numTets);
        sumSamples = new eavlIntArray("",1,numTets);
        iterator      = new eavlIntArray("",1, numTets);
        dummy = new eavlFloatArray("",1,1); //wtf
        for(int i=0; i < numTets; i++) iterator->SetValue(i,i);
        //readTransferFunction(tfFilename);
        geomDirty = false;
    }

    //we are trying to keep the mem usage down. We will conservativily estimate the number of
    //indexes to keep in here. Edge case would we super zoomed in a particlar region which
    //would maximize the wasted space.
    
    if(!firstPass)
    {
        float ratio = maxPassSize / (float) passCountEstimate;
        if(ratio < .9 || ratio > 1.f) 
        {
            passCountEstimate = maxPassSize + (int)(maxPassSize * .1); //add a little padding here.
            passNumDirty = true;
            cout<<"Ajdusting Pass size"<<endl;
        }
    }

    if(passNumDirty)
    {
        if(verbose) cout<<"Pass Dirty"<<endl;
        if(firstPass) 
        {
       
            passCountEstimate = (int)((numTets / numPasses) * PASS_ESTIMATE_FACTOR); //TODO: see how close we can cut this
            if(numPasses == 1) passCountEstimate = numTets;
            maxPassSize =-1;
            firstPass = false;
        }
        deleteClassPtr(currentPassMembers);
        deleteClassPtr(reverseIndex);
        deleteClassPtr(ssa);
        deleteClassPtr(ssb);
        deleteClassPtr(ssc);
        deleteClassPtr(ssd);
        deleteClassPtr(screenIterator);
        if(false && numPasses == 1)
        {
            currentPassMembers = iterator;
        }
        else
        {   //we don't need to allocate this if we are only doing one pass
            currentPassMembers = new eavlIntArray("",1, passCountEstimate);
            reverseIndex = new eavlIntArray("",1, passCountEstimate); 
        }
        int size = width * height;
        screenIterator  = new eavlIntArray("",1,size);
        for(int i=0; i < size; i++) screenIterator->SetValue(i,i);
        int space  = passCountEstimate*3;
        if(space < 0) cout<<"ERROR int overflow"<<endl;
        if(verbose) cout<<"allocating pce "<<passCountEstimate<<endl;
        ssa = new eavlFloatArray("",1, passCountEstimate*3); 
        ssb = new eavlFloatArray("",1, passCountEstimate*3);
        ssc = new eavlFloatArray("",1, passCountEstimate*3);
        ssd = new eavlFloatArray("",1, passCountEstimate*3);
        passNumDirty = false;
    }
    
    calcMemoryRequirements();
}

//-------------------------------------------------

struct PassThreshFunctor
{
    int passId;
    PassThreshFunctor(int _passId) : passId(_passId)
    {}

    EAVL_FUNCTOR tuple<int> operator()(tuple<int,int> input){
        int minp = get<0>(input);
        int maxp = get<1>(input);
        if((minp <= passId) && (maxp >= passId)) return tuple<int>(1);
        else return tuple<int>(0);
    }
};

//-------------------------------------------------

void eavlSimpleVRMutator::performScreenSpaceTransform(eavlIntArray *tetIds, int number)
{
    //cerr<<"IN PerformScreen\n";
	int numPassMembers = tetIds->GetNumberOfTuples();
    int outputArraySize = ssa->GetNumberOfTuples() / 3;
   
  // cerr<<"Number of Big Cells "<<numPassMembers<<"\n"; 

   if(numPassMembers > outputArraySize)
    {
        cout<<"WARNING!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
        cout<<"Too many input cells for screen space transform\n";
        exit(1);
    }

    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(tetIds),
                                                     eavlOpArgs(eavlIndexable<eavlFloatArray>(ssa,*i1),
                                                                eavlIndexable<eavlFloatArray>(ssa,*i2),
                                                                eavlIndexable<eavlFloatArray>(ssa,*i3),
                                                                eavlIndexable<eavlFloatArray>(ssb,*i1),
                                                                eavlIndexable<eavlFloatArray>(ssb,*i2),
                                                                eavlIndexable<eavlFloatArray>(ssb,*i3),
                                                                eavlIndexable<eavlFloatArray>(ssc,*i1),
                                                                eavlIndexable<eavlFloatArray>(ssc,*i2),
                                                                eavlIndexable<eavlFloatArray>(ssc,*i3),
                                                                eavlIndexable<eavlFloatArray>(ssd,*i1),
                                                                eavlIndexable<eavlFloatArray>(ssd,*i2),
                                                                eavlIndexable<eavlFloatArray>(ssd,*i3)),
                                                    ScreenSpaceFunctor(xtet,ytet,ztet,view, nSamples, xmin,ymin,zmin),number),
                                                    "Screen Space transform");
    
	
    //cerr<<"AddOperation done\n";
	eavlExecutor::Go();
	//cerr<<"Executor done\n";
}

void eavlSimpleVRMutator::findCurrentPassMembers(int pass)
{
    int passtime;
    if(verbose)  passtime = eavlTimer::Start();

    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(minPasses,maxPasses),
                                         eavlOpArgs(mask),
                                         PassThreshFunctor(pass)),
                                         "find pass members");

    eavlExecutor::Go();
    eavlExecutor::AddOperation(new eavlPrefixSumOp_1(mask,indexScan,false), //inclusive==true exclusive ==false
                                                     "create indexes");
    eavlExecutor::Go();

    eavlExecutor::AddOperation(new eavlReduceOp_1<eavlAddFunctor<int> >
                              (mask,
                               passCount,
                               eavlAddFunctor<int>()),
                               "count output");
    eavlExecutor::Go();

    passSize = passCount->GetValue(0);
    maxPassSize = max(maxPassSize, passSize);

    if(passSize > passCountEstimate)
    {
      cout<<"WARNING Exceeded max passSize:  maxPassSize "<<maxPassSize<<" estimate "<<passCountEstimate<<endl;  
      passNumDirty = true;
      THROW(eavlException, "exceeded max pass size.");
    } 

    if(passSize == 0)
    {
        return;
    }
    
    eavlExecutor::AddOperation(new eavlSimpleReverseIndexOp(mask,
                                                            indexScan,
                                                            reverseIndex),
                                                            "generate reverse lookup");
    eavlExecutor::Go();
    
    eavlExecutor::AddOperation(new_eavlGatherOp(eavlOpArgs(iterator),
                                                eavlOpArgs(currentPassMembers),
                                                eavlOpArgs(reverseIndex),
                                                passSize),
                                                "pull in the tets for this pass");
    eavlExecutor::Go();
    

    if(verbose) passSelectionTime += eavlTimer::Stop(passtime,"pass");
}

//-------------------------------------------------
void  eavlSimpleVRMutator::Execute()
{
    //
    // If we are doing parallel compositing, we just want the partial
    // composites without the background color
    //
    //cout<<view.P<<" \n"<<view.V<<endl;
    // view.SetupMatrices();
    // cout<<view.P<<" \n"<<view.V<<endl;
    //cerr<<"IN execute\n";
    if(isTransparentBG) 
    {
        bgColor.c[0] =0.f; 
        bgColor.c[1] =0.f; 
        bgColor.c[2] =0.f; 
        bgColor.c[3] =0.f;
    }

    //timing accumulators
    double clearTime = 0;
    passFilterTime = 0;
    compositeTime = 0;
    passSelectionTime = 0;
    sampleTime = 0;
    allocateTime = 0;
    screenSpaceTime = 0;
    renderTime = 0;
   
    int tets = scene->getNumTets();
    //eavlPartialComp* rays; 
   
    if(tets != numTets)
    {
        geomDirty = true;
        numTets = tets;
    }
    if(verbose) 
       cout<<"Num Tets = "<<numTets<<endl;

    // Pixels extents are used to skip empty space in compositing
    // and for allocating sample buffer
    eavlPoint3 mins(scene->getSceneBBox().min.x,scene->getSceneBBox().min.y,scene->getSceneBBox().min.z);
    eavlPoint3 maxs(scene->getSceneBBox().max.x,scene->getSceneBBox().max.y,scene->getSceneBBox().max.z);
    getBBoxPixelExtent(mins,maxs);
    //
    //  Set sample buffer information
    //
    xmin = mins.x;
    ymin = mins.y;
    zmin = mins.z;
    int new_dx = maxs.x - mins.x;
    int new_dy = maxs.y - mins.y;
    int new_dz = maxs.z - mins.z;
    //cerr<<"Before if sizeDirty\n";
    if(new_dx != dx || new_dy != dy || new_dz != dz) sizeDirty = true;
    dx = new_dx;
    dy = new_dy;
    dz = new_dz;
    //cerr<<"After sizeDirty\n";
    int tinit;
    if(verbose) tinit = eavlTimer::Start();
    init();
    //cerr<<"After init\n";
    //cerr<<"num of tets "<<tets<<"\n";
    if(tets < 1)
    {
        //There is nothing to render. Set depth and framebuffer
        eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(minSample),
                                             eavlOpArgs(minSample),
                                             IntMemsetFunctor(nSamples+1000)), //what should this be?
                                             "clear first sample");
        eavlExecutor::Go();

        //cerr<<"clear first sample for tets <0 \n";
        
        eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(framebuffer),
                                             eavlOpArgs(framebuffer),
                                             FloatMemsetFunctor(0)),
                                             "clear Frame Buffer");
        eavlExecutor::Go();

        //cerr<<"clear Frame Buffer for tets <0 \n";

        eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(eavlIndexable<eavlFloatArray>(framebuffer,*ir),
                                                             eavlIndexable<eavlFloatArray>(framebuffer,*ig),
                                                             eavlIndexable<eavlFloatArray>(framebuffer,*ib),
                                                             eavlIndexable<eavlFloatArray>(framebuffer,*ia)),
                                                  eavlOpArgs(eavlIndexable<eavlFloatArray>(framebuffer,*ir),
                                                             eavlIndexable<eavlFloatArray>(framebuffer,*ig),
                                                             eavlIndexable<eavlFloatArray>(framebuffer,*ib),
                                                             eavlIndexable<eavlFloatArray>(framebuffer,*ia)),
                                                 CompositeBG(bgColor), height*width),
                                                 "Composite");
        eavlExecutor::Go();

        //cerr<<"Composite for tets <0 \n";
        return;
    }
    
    
    //cerr<<"Before cpu gpu stuff \n";
    if(!cpu)
    {
        //cout<<"Getting cuda array for tets."<<endl;
        xtet = (float4*) tetSOA[0]->GetCUDAArray();
        ytet = (float4*) tetSOA[1]->GetCUDAArray();
        ztet = (float4*) tetSOA[2]->GetCUDAArray();
    }
    else 
    {
        xtet = (float4*) tetSOA[0]->GetHostArray();
        ytet = (float4*) tetSOA[1]->GetHostArray();
        ztet = (float4*) tetSOA[2]->GetHostArray();
    }
    float* samplePtr;
    //PartialComposite* raysPtr;
    if(!cpu)
    {
        samplePtr = (float*) samples->GetCUDAArray();
        //raysPtr      = (PartialComposite*) rays->GetCUDAArray();
    }
    else 
    {
        samplePtr = (float*) samples->GetHostArray();
        //raysPtr      = (PartialComposite*) rays->GetCUDAArray();
    }

    float* alphaPtr;
    if(!cpu)
    {
        alphaPtr = (float*) framebuffer->GetCUDAArray();
    }
    else 
    {
        alphaPtr = (float*) framebuffer->GetHostArray();
    }
    if(verbose) cout<<"Init        RUNTIME: "<<eavlTimer::Stop(tinit,"init")<<endl;

    int ttot;
    if(verbose) ttot = eavlTimer::Start();

    if(verbose)
    {
        cout<<"BBox Screen Space "<<mins<<maxs<<endl; 
    }
    int tclear;
    if(verbose) tclear = eavlTimer::Start();

    //cerr<<"Bfore adding operations \n";
    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(framebuffer),
                                             eavlOpArgs(framebuffer),
                                             FloatMemsetFunctor(0)),
                                             "clear Frame Buffer");
    eavlExecutor::Go();

    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(zBuffer),
                                             eavlOpArgs(zBuffer),
                                             FloatMemsetFunctor(1.f)),
                                             "clear Frame Buffer");
    eavlExecutor::Go();
    
     eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(minSample),
                                             eavlOpArgs(minSample),
                                             IntMemsetFunctor(nSamples+1000)), //TODO:Maybe this should be higher
                                             "clear first sample");
    eavlExecutor::Go();
   
    
    
     if(verbose) 
        cout<<"ClearBuffs  RUNTIME: "<<eavlTimer::Stop(tclear,"")<<endl;

    int ttrans;
    if(verbose) ttrans = eavlTimer::Start();
    if(false && numPasses == 1)
    {
        //just set all tets to the first pass
        eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(minPasses),
                                             eavlOpArgs(minPasses),
                                             IntMemsetFunctor(0)),
                                             "set");
        eavlExecutor::Go();
        eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(maxPasses),
                                             eavlOpArgs(maxPasses),
                                             IntMemsetFunctor(0)),
                                             "set");
        eavlExecutor::Go();
        //passSize = numTets;
    }
    else
    {
        //find the min and max passes the tets belong to
        cerr<<"Calling PassRange with sampleLCFlag value = "<<sampleLCFlag<<"\n";
        eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(iterator),
                                             eavlOpArgs(minPasses, maxPasses,sumSamples),
                                             PassRange(xtet,ytet,ztet, view, nSamples, numPasses, zmin,dz,sampleLCFlag)),
                                             "PassFilter");
        eavlExecutor::Go(); 
    }
    

    if(verbose) passFilterTime =  eavlTimer::Stop(ttrans,"ttrans");
        
    
    //cout<<"Pass Z stride "<<passZStride<<endl;
    for(int i = 0; i < numPasses; i++)
    {
        // ins sample space
        int pixelZMin = passZStride * i;
        int pixelZMax = passZStride * (i + 1) - 1;
      
        try
        {
            //if(numPasses > 1) 
                findCurrentPassMembers(i);
        }
        catch(eavlException &e)
        {
            return;
        }
        
        //cerr<<"Pass size "<<passSize<<"\n";
        
        if(passSize > 0)
        {

            int tclearS;
            if(verbose) tclearS = eavlTimer::Start();
            if (i != 0) clearSamplesArray();  //this is a win on CPU for sure, gpu seems to be the same
            //cerr<<"clearSamplesArray is done\n";
            // eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(samples),
            //                                          eavlOpArgs(samples),
            //                                          FloatMemsetFunctor(-1.f)),
            //                                          "clear Frame Buffer");
            // eavlExecutor::Go();
            if(verbose) clearTime += eavlTimer::Stop(tclearS,"");
                
            int tsspace;
            if(verbose) tsspace = eavlTimer::Start();
            
           // cerr<<"Before screen space transformation\n";
            performScreenSpaceTransform(currentPassMembers,passSize);

	        //cerr<<"Done Screen Space Transform\n";
    
            if(verbose) screenSpaceTime += eavlTimer::Stop(tsspace,"sample");
            int tsample;
            if(verbose) tsample = eavlTimer::Start();
            //Call Sample function
            eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(eavlIndexable<eavlIntArray>(currentPassMembers),
                                                        eavlIndexable<eavlFloatArray>(ssa,*i1),
                                                        eavlIndexable<eavlFloatArray>(ssa,*i2),
                                                        eavlIndexable<eavlFloatArray>(ssa,*i3),
                                                        eavlIndexable<eavlFloatArray>(ssb,*i1),
                                                        eavlIndexable<eavlFloatArray>(ssb,*i2),
                                                        eavlIndexable<eavlFloatArray>(ssb,*i3),
                                                        eavlIndexable<eavlFloatArray>(ssc,*i1),
                                                        eavlIndexable<eavlFloatArray>(ssc,*i2),
                                                        eavlIndexable<eavlFloatArray>(ssc,*i3),
                                                        eavlIndexable<eavlFloatArray>(ssd,*i1),
                                                        eavlIndexable<eavlFloatArray>(ssd,*i2),
                                                        eavlIndexable<eavlFloatArray>(ssd,*i3)),
                                                        eavlOpArgs(eavlIndexable<eavlFloatArray>(dummy,*idummy)), 
                                                     SampleFunctor3(scalars_array, view, nSamples, samplePtr, pixelZMin, pixelZMax, passZStride, alphaPtr, dx, dy,dz, xmin,ymin),passSize),
                                                     "Sampler");
           eavlExecutor::Go();
            //cerr<<"  Done Sampling \n";


            if(verbose) sampleTime += eavlTimer::Stop(tsample,"sample");
            int talloc;
            if(verbose) talloc = eavlTimer::Start();

            if(verbose) allocateTime += eavlTimer::Stop(talloc,"sample");
            //eavlArrayIndexer * ifb = new eavlArrayIndexer(1, offset);
            //cout<<"screenIterator last value "<<screenIterator->GetS
            bool finalPass = (i == numPasses - 1) ? true : false;
            int tcomp;
            if(verbose) tcomp = eavlTimer::Start();
      
            numOfPartials = new eavlIntArray("",1,width*height);
            //cerr<<"**** pixel 0,0 "<<numOfPartials->GetValue(0)<<"\n";
            eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(screenIterator),
                                             eavlOpArgs(numOfPartials),
                                             GetNumOfPartialCompNum( view, nSamples, samplePtr, color_map_array, colormapSize, mins, maxs, passZStride, finalPass, pixelsPerPass,pixelZMin, dx,dy,xmin,ymin), width*height),
                                             "number of partials");


            eavlExecutor::Go();

            //cerr<<"Num of components "<<numOfPartials->GetNumberOfTuples()<<"\n";
            //for(int i=0; i< numOfPartials->GetNumberOfTuples(); i++)
               // if(numOfPartials->GetValue(i)!=0)
                //cerr<<"Num of partials for item "<<i<<" is "<<numOfPartials->GetValue(i)<<"\n";


             totalNumberOfPArtials = new eavlIntArray("",1,1); 
             //totalNumberOfPArtials = 0;
             eavlExecutor::AddOperation(new eavlReduceOp_1<eavlAddFunctor<int> >
                              (numOfPartials,
                               totalNumberOfPArtials,
                               eavlAddFunctor<int>()),
                               "count total number of partials");

             eavlExecutor::Go();
             //cerr<<"Actual data size "<<dx*dy<<"\n";
             //cerr<<"Total number of partials "<<totalNumberOfPArtials->GetValue(0)<<"\n";

            offesetPartials = new eavlIntArray("",1,width*height);

            //False = exclusive scan output counts to get output index
            //IMPORTANT: I want to set it to false because true generates errors
            //Explination on my Doc
            eavlExecutor::AddOperation(new eavlPrefixSumOp_1(numOfPartials,
                              offesetPartials,
                              false),
                            "scan to generate starting out offeset");
                            
            eavlExecutor::Go();

            
            int raySize = totalNumberOfPArtials->GetValue(0) * 8;
            //cerr<<"Ray size "<<raySize<<"\n";
            myFloatrays = new eavlFloatArray("",1, raySize);
            
            float* raysPtr;
             if(!cpu) raysPtr      = (float*) myFloatrays->GetCUDAArray();
            else      raysPtr      = (float*) myFloatrays->GetHostArray();

            
            /*
            eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(eavlIndexable<eavlIntArray>(currentPassMembers)),
                                                     eavlOpArgs(eavlIndexable<eavlFloatArray>(dummy,*idummy)),
                                                     TestMyStruct(raysPtr,offesetPartials)),
                                                     "Test Map on rays");

            eavlExecutor::Go();*/

            //cerr<<"******** Test my Functor "<<myFloatrays->GetValue(0)<<"\n";

    
            eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(eavlIndexable<eavlIntArray>(screenIterator),
                                                                eavlIndexable<eavlIntArray>(minSample)),
                                                       eavlOpArgs(eavlIndexable<eavlFloatArray>(dummy,*idummy)),
                                                       GetPartialComposites( view, nSamples, samplePtr,raysPtr,offesetPartials,  color_map_array, colormapSize, mins, maxs, passZStride, finalPass, pixelsPerPass,pixelZMin, dx,dy,xmin,ymin,numOfPartials), width*height),
                                                       "Get Partial Composite");

            eavlExecutor::Go();

           //cerr<<"Got Partials \n";
            
             
            //-----------------------------------------------
            
            
             eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(eavlIndexable<eavlIntArray>(screenIterator),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ir),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ig),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ib),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ia),
                                                                 eavlIndexable<eavlIntArray>(minSample)),
                                                      eavlOpArgs(eavlIndexable<eavlFloatArray>(framebuffer,*ir),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ig),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ib),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ia),
                                                                 eavlIndexable<eavlIntArray>(minSample)),
                                                     CompositeFunctorFB( view, nSamples, samplePtr, color_map_array, colormapSize, mins, maxs, passZStride, finalPass, pixelsPerPass,pixelZMin, dx,dy,xmin,ymin), width*height),
                                                     "Composite");


            
	    //cerr<<"Add composite op\n";
	    eavlExecutor::Go();
	    //cerr<<"Done composite \n";
            if(verbose) compositeTime += eavlTimer::Stop(tcomp,"tcomp");

	   // cerr<<"Done composite \n";

        }//if(passSize > 0)
        else 
            {   //Did this to avoid having Segmentation fault when passSize = 0
                //Check with Matt, use the testvolume example with all LC
                myFloatrays = new eavlFloatArray("",1, 0);
                //To avoid having Segmentation fault when passSize = 0
                totalNumberOfPArtials = new eavlIntArray("",1,1);
            }
    }//for each pass
    if(verbose) renderTime  = eavlTimer::Stop(ttot,"total render");
    if(verbose) cout<<"PassFilter  RUNTIME: "<<passFilterTime<<endl;
   // cout<<"Clear Sample  RUNTIME: "<<clearTime<<endl;
    if(verbose) cout<<"PassSel     RUNTIME: "<<passSelectionTime<<" Pass AVE: "<<passSelectionTime / (float)numPasses<<endl;
    if(verbose) cout<<"ScreenSpace RUNTIME: "<<screenSpaceTime<<" Pass AVE: "<<screenSpaceTime / (float)numPasses<<endl;
    if(verbose) cout<<"Sample      RUNTIME: "<<sampleTime<<" Pass AVE: "<<sampleTime / (float)numPasses<<endl;
    if(verbose) cout<<"Composite   RUNTIME: "<<compositeTime<<" Pass AVE: "<<compositeTime / (float)numPasses<<endl;
    if(verbose) cout<<"Alloc       RUNTIME: "<<allocateTime<<" Pass AVE: "<<allocateTime / (float)numPasses<<endl;
    if(verbose) cout<<"Total       RUNTIME: "<<renderTime<<endl;
    //dataWriter();
    //composite my pixel color with background

    //cerr<<"Before composite\n";
 eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ir),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ig),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ib),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ia)),
                                                      eavlOpArgs(eavlIndexable<eavlFloatArray>(framebuffer,*ir),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ig),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ib),
                                                                 eavlIndexable<eavlFloatArray>(framebuffer,*ia)),
                                                     CompositeBG(bgColor), height*width),
                                                     "Composite");
    eavlExecutor::Go();

    //cerr<<"After composte \n";
}


inline bool exists (const std::string& name) {
    ifstream f(name.c_str());
    if (f.good()) {
        f.close();
        return true;
    } else {
        f.close();
        return false;
    }   
}

//-------------------------------------------------

void  eavlSimpleVRMutator::dataWriter()
{
  string sCPU = "_CPU_";
  string sGPU = "_GPU_";
  string dfile;
  if(cpu) dfile = "datafile_" + sCPU + dataname + ".dat";
  else dfile = "datafile_" + sGPU + dataname + ".dat";  
   
  if(!exists(dfile))
  {
    ofstream boilerplate;
    boilerplate.open (dfile.c_str());
    boilerplate << "Step\n";
    boilerplate << "Pass Filter\n";
    boilerplate << "Pass Selection\n";
    boilerplate << "Screen Space\n";
    boilerplate << "Sampling\n";
    boilerplate << "Compostiting\n";
    boilerplate << "Render\n";
    boilerplate.close();
  }
  string separator = ",";
  string line[7];
  double times[6];
  times[0] = passFilterTime;
  times[1] = passSelectionTime;
  times[2] = screenSpaceTime;
  times[3] = sampleTime;
  times[4] = compositeTime;
  times[5] = renderTime;

  ifstream dataIn (dfile.c_str());
  if (dataIn.is_open())
  {
    for(int i = 0; i < 7; i++)
    {
        getline (dataIn,line[i]);
        //cout << line[i] << '\n';
    }
    dataIn.close();
  }
  else
  {
    cout << "Unable to open file"<<endl;
    return; 
  }
  ofstream dataOut (dfile.c_str());
  if (dataOut.is_open())
  {
    for(int i = 0; i < 7; i++)
    {
         if(i ==  0) dataOut << line[i] << separator <<numPasses<<endl;
         else dataOut << line[i] << separator <<times[i-1]<<endl;
    }
    
    dataOut.close();
  }
  else dataOut << "Unable to open file";
    string space = " ";

}

//-------------------------------------------------

void  eavlSimpleVRMutator::freeTextures()
{
    if (scalars_array != NULL) 
    {
        scalars_array->unbind(scalars_tref);
        delete scalars_array;
        scalars_array = NULL;
    }

}

//-------------------------------------------------

void  eavlSimpleVRMutator::freeRaw()
{
}

//-------------------------------------------------
void eavlSimpleVRMutator::readTransferFunction(string filename)
{

    std::fstream file(filename.c_str(), std::ios_base::in);
    if(file != NULL)
    {
        //file format number of peg points, then peg points 
        //peg point 0 0 255 255 0.0241845 //RGBA postion(float)
        int numPegs;
        file>>numPegs;
        if(numPegs >= COLOR_MAP_SIZE || numPegs < 1) 
        {
            cerr<<"Invalid number of peg points, valid range [1,1024]: "<<numPegs<<endl;
            exit(1);
        } 

        float *rgb = new float[numPegs*3];
        float *positions = new float[numPegs];
        int trash;
        for(int i = 0; i < numPegs; i++)
        {
            file>>rgb[i*3 + 0];
            file>>rgb[i*3 + 1];
            file>>rgb[i*3 + 2];
            rgb[i*3 + 0] = rgb[i*3 + 0] / 255.f; //normalize
            rgb[i*3 + 1] = rgb[i*3 + 1] / 255.f; //normalize
            rgb[i*3 + 2] = rgb[i*3 + 2] / 255.f; //normalize
            file>>trash;
            file>>positions[i];

        }
        //next we read in the free form opacity
        int numOpacity;
        file>>numOpacity;
        if(numOpacity >= COLOR_MAP_SIZE || numOpacity < 1) 
        {
            cerr<<"Invalid number of opacity points, valid range [1,1024]: "<<numOpacity<<endl;
            exit(1);
        } 
        float *opacityPoints = new float[numOpacity];
        float *opacityPositions = new float[numOpacity];
        cout<<"Num opacity "<<numOpacity<<endl;
        for(int i = 0; i < numOpacity; i++)
        {
            file>>opacityPoints[i];
            cout<<"Opacity point "<<opacityPoints[i]<<endl;
            opacityPoints[i] = (opacityPoints[i] / 255.f ) * opacityFactor; //normalize
            cout<<"Opacity point 2"<<opacityPoints[i]<<endl;
            opacityPositions[i] = i / (float) numOpacity;
        }
        cout<<endl;
        //build the color map

        int rgbPeg1 = 0;
        int rgbPeg2 = 1;

        int opacityPeg1 = 0;
        int opacityPeg2 = 1;
        
        float currentPosition = 0.f;
        float *colorMap = new float[COLOR_MAP_SIZE * 4];

        //fill in rgb values
        float startPosition;
        float endPosition;
        float4 startColor = {0,0,0,0};
        float4 endColor = {0,0,0,0};
        //init color and positions
        if(positions[rgbPeg1] == 0.f)
        {
            startPosition = positions[rgbPeg1];
            startColor.x = rgb[rgbPeg1*3 + 0];
            startColor.y = rgb[rgbPeg1*3 + 1];
            startColor.z = rgb[rgbPeg1*3 + 2];
            endPosition = positions[rgbPeg2];
            endColor.x = rgb[rgbPeg2*3 + 0];
            endColor.y = rgb[rgbPeg2*3 + 1];
            endColor.z = rgb[rgbPeg2*3 + 2];
        }
        else
        {
            //cout<<"init 0 start"<<endl;
            startPosition = 0;
            //color already 0
            endPosition = positions[rgbPeg1];
            endColor.x = rgb[rgbPeg1*3 + 0];
            endColor.y = rgb[rgbPeg1*3 + 1];
            endColor.z = rgb[rgbPeg1*3 + 2];
        }

        for(int i = 0; i < COLOR_MAP_SIZE; i++)
        {
            
            currentPosition = i / (float)COLOR_MAP_SIZE;

            float t = (currentPosition - startPosition) / (endPosition - startPosition);
            colorMap[i*4 + 0] = lerp(startColor.x, endColor.x, t);
            colorMap[i*4 + 1] = lerp(startColor.y, endColor.y, t);
            colorMap[i*4 + 2] = lerp(startColor.z, endColor.z, t);

            if( (currentPosition > endPosition) )
            {
                //advance peg points

                rgbPeg1++;
                rgbPeg2++;  
                //reached the last Peg point 
                if(rgbPeg2 >= numPegs) 
                {
                    startPosition = positions[rgbPeg1];
                    startColor.x = rgb[rgbPeg1*3 + 0];
                    startColor.y = rgb[rgbPeg1*3 + 1];
                    startColor.z = rgb[rgbPeg1*3 + 2];
                    //just keep the same color, we could change this to 0
                    endPosition = 1.f;
                    endColor.x = rgb[rgbPeg1*3 + 0];
                    endColor.y = rgb[rgbPeg1*3 + 1];
                    endColor.z = rgb[rgbPeg1*3 + 2];

                }
                else
                {
                    startPosition = positions[rgbPeg1];
                    startColor.x = rgb[rgbPeg1*3 + 0];
                    startColor.y = rgb[rgbPeg1*3 + 1];
                    startColor.z = rgb[rgbPeg1*3 + 2];
                    endPosition = positions[rgbPeg2];
                    endColor.x = rgb[rgbPeg2*3 + 0];
                    endColor.y = rgb[rgbPeg2*3 + 1];
                    endColor.z = rgb[rgbPeg2*3 + 2];
                }

            }
        }

        float startAlpha = 0.f;
        float endAlpha = 1.f;
        if(positions[opacityPeg1] == 0.f)
        {
            startPosition = opacityPositions[opacityPeg1];
            startAlpha = opacityPoints[opacityPeg1];
            endPosition = opacityPositions[opacityPeg2];
            endAlpha = opacityPoints[opacityPeg2];
        }
        else
        {
            startPosition = 0.f;
            startAlpha = 0.f;
            endPosition = opacityPoints[opacityPeg1];
            endAlpha = opacityPoints[opacityPeg1];
        }
        // fill in alphas
        for(int i = 0; i < COLOR_MAP_SIZE; i++)
        {
           
            currentPosition = i / (float)COLOR_MAP_SIZE;

            float t = (currentPosition - startPosition) / (endPosition - startPosition);
            colorMap[i*4 + 3] = lerp(startAlpha, endAlpha, t);

            //cout<<colorMap[i*4+0]<<" "<<colorMap[i*4+1]<<" "<<colorMap[i*4+2]<<" "<<colorMap[i*4+3]<<" pos "<<currentPosition<<endl;
            if(currentPosition > endPosition)
            {
                //advance peg points

                opacityPeg1++;
                opacityPeg2++;  
                //reached the last Peg point
                if(opacityPeg2 >= numOpacity) 
                {
                    startPosition = opacityPositions[opacityPeg1];
                    startAlpha = opacityPoints[opacityPeg1];
                   
                    //just keep the same color, we could change this to 0
                    endPosition = 1.f;
                    endAlpha = opacityPoints[opacityPeg1];
                    

                }
                else
                {
                    startPosition = opacityPositions[opacityPeg1];
                    startAlpha = opacityPoints[opacityPeg1];
                   
                    endPosition = opacityPositions[opacityPeg2];
                    endAlpha = opacityPoints[opacityPeg2];
                   
                }
            }
        }

        setColorMap4f(colorMap, COLOR_MAP_SIZE);
        delete[] rgb;
        delete[] positions;
        delete[] opacityPoints;
        delete[] opacityPositions;
    }
    else 
    {
        cerr<<"Could not open tranfer function file : "<<filename.c_str()<<endl;
    }
}

eavlByteArray * eavlSimpleVRMutator::getFrameBuffer()
{
    
    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(framebuffer),
                                             eavlOpArgs(rgba),
                                             CastToUnsignedCharFunctor()),
                                             "set");
    eavlExecutor::Go();
    return rgba;
}
eavlFloatArray * eavlSimpleVRMutator::getRealFrameBuffer()
{
    return framebuffer;
}
void eavlSimpleVRMutator::setSampleLCFlag(int val)
{
    sampleLCFlag = val; 
    cerr<<"sampleLCFlag value changes to "<<sampleLCFlag<<"\n";
}

void eavlSimpleVRMutator::getImageSubsetDims(int *dims)
{
  dims[0] = xmin;
  dims[1] = ymin;
  dims[2] = dx;
  dims[3] = dy;

}

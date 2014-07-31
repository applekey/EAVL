#include "eavlVolumeRendererMutator.h"
#include "eavlException.h"
#include "eavlExecutor.h"
#include "RT/eavlRTUtil.h"
#include "eavlMapOp.h"
#include "eavlFilter.h"
#include "eavlTimer.h" 
#include "RT/SplitBVH.h"

#define USE_TEXTURE_MEM
#define END_FLAG    -1000000000
#define INFINITE    1000000
#define EPSILON     0.001f

/* Triangle textures */
texture<float4> tet_bvh_in_tref;            /* BVH inner nodes */
texture<float4> tet_verts_tref;              /* vert+ scalar data */
texture<float>  tet_bvh_lf_tref;            /* BVH leaf nodes */

#ifndef HAVE_CUDA
template<class T> class texture {};
struct float4
{
    float x,y,z,w;
};
#endif

template<class T>
class eavlConstArrayV2
{
  public:
    T *host;
    T *device;
  public:
    eavlConstArrayV2(T *from, int N, texture<T> &g_textureRef)
    {
        host = from;

#ifdef HAVE_CUDA
        int nbytes = N * sizeof(T);
        cudaMalloc((void**)&device, nbytes);
        CUDA_CHECK_ERROR();
        cudaMemcpy(device, &(host[0]),
                   nbytes, cudaMemcpyHostToDevice);
        CUDA_CHECK_ERROR();
#ifdef USE_TEXTURE_MEM
        cudaBindTexture(0, g_textureRef,device,nbytes);
        CUDA_CHECK_ERROR();
#endif

#endif
    }
    ~eavlConstArrayV2()
    {
        

#ifdef HAVE_CUDA
        //cudaFree(device);
        //CUDA_CHECK_ERROR();
#endif


    }
#ifdef __CUDA_ARCH__
#ifdef USE_TEXTURE_MEM
    EAVL_DEVICEONLY  const T getValue(texture<T> g_textureRef, int index) const
    {
        return tex1Dfetch(g_textureRef, index);
    }
    EAVL_HOSTONLY  void unbind(texture<T> g_textureRef)
    {
        cudaUnbindTexture(g_textureRef);
        CUDA_CHECK_ERROR();
    }
#else
    EAVL_DEVICEONLY const T &getValue(texture<T> g_textureRef, int index) const
    {
        return device[index];
    }
    EAVL_HOSTONLY  void unbind(texture<T> g_textureRef)
    {
        //do nothing
    }
#endif
#else
    EAVL_HOSTONLY const T &getValue(texture<T> g_textureRef, int index) const
    {
        return host[index];
    }
    EAVL_HOSTONLY  void unbind(texture<T> g_textureRef)
    {
        //do nothing
    }
#endif

};


eavlConstArrayV2<float4>* tet_bvh_in_array;
eavlConstArrayV2<float4>* tet_verts_array;
eavlConstArrayV2<float>*  tet_bvh_lf_array;

eavlVolumeRendererMutator::eavlVolumeRendererMutator()
{
	height = 1080;
	width  = 1920;
	size = height * width;
	camera.position.x = 10;
	camera.position.y = 0;
	camera.position.z = 0;
	camera.lookat.x = 0;
	camera.lookat.y = 0;
	camera.lookat.z = 0;
	camera.up.x = 0;
	camera.up.y = 1;
	camera.up.z = 0;
	camera.fovx = 45;
	camera.fovy = 30;
	camera.zoom = 1;

	rayOriginX = NULL;
    rayOriginY = NULL;
    rayOriginZ = NULL;
    rayDirX = NULL;
    rayDirY = NULL;
    rayDirZ = NULL;
    indexes = NULL;
    mortonIndexes = NULL;
    r = NULL;
    g = NULL;
    b = NULL;

    geomDirty = true;
    sizeDirty = true;
    verbose = true;

    tet_verts_raw = NULL;
    tet_bvh_in_raw = NULL;     
    tet_bvh_lf_raw = NULL;

    tet_bvh_in_array = NULL;
    tet_verts_array = NULL;
    tet_bvh_lf_array = NULL;
    numTets = 0;

    gpu = true;
}


EAVL_HOSTDEVICE int getIntersectionTet(const eavlVector3 rayDir, const eavlVector3 rayOrigin, const eavlConstArrayV2<float4> &bvh,const eavlConstArrayV2<float> &tet_bvh_lf_raw,eavlConstArrayV2<float4> &verts,const float &maxDistance, float &distance, float sampleDelta)
{
    cout<<"New ray --------------------------------------------------------"<<endl;

    float minDistance = maxDistance;
    int   minIndex    = -1;
    float nextSampleDistance = 0;
    float dirx = rayDir.x;
    float diry = rayDir.y;
    float dirz = rayDir.z;

    float invDirx = rcp_safe(dirx);
    float invDiry = rcp_safe(diry);
    float invDirz = rcp_safe(dirz);
    int currentNode;
  
    int todo[64]; //num of nodes to process
    int stackptr = 0;
    int barrier  = (int)END_FLAG;
    currentNode  = 0;

    todo[stackptr] = barrier;

    float ox = rayOrigin.x;
    float oy = rayOrigin.y;
    float oz = rayOrigin.z;
    float odirx = ox*invDirx;
    float odiry = oy*invDiry;
    float odirz = oz*invDirz;

    while(currentNode!=END_FLAG) {
        

        
        if(currentNode>-1)
        {

            float4 n1=bvh.getValue(tet_bvh_in_tref, currentNode  ); //(txmin0, tymin0, tzmin0, txmax0)
            float4 n2=bvh.getValue(tet_bvh_in_tref, currentNode+1); //(tymax0, tzmax0, txmin1, tymin1)
            float4 n3=bvh.getValue(tet_bvh_in_tref, currentNode+2); //(tzmin1, txmax1, tymax1, tzmax1)
            
            float txmin0 =   n1.x*invDirx - odirx;       
            float tymin0 =   n1.y*invDiry - odiry;         
            float tzmin0 =   n1.z*invDirz - odirz;
            float txmax0 =   n1.w*invDirx - odirx;
            float tymax0 =   n2.x*invDiry - odiry;
            float tzmax0 =   n2.y*invDirz - odirz;
           
            float tmin0 = max(max(max(min(tymin0,tymax0),min(txmin0,txmax0)),min(tzmin0,tzmax0)),0.f); //maxDistance, how will this effect travseral if we change it on the fly
            float tmax0 = min(min(min(max(tymin0,tymax0),max(txmin0,txmax0)),max(tzmin0,tzmax0)), minDistance);
            
            bool traverseChild0 = (tmax0 >= tmin0); 

             
            float txmin1 =   n2.z*invDirx - odirx;       
            float tymin1 =   n2.w*invDiry - odiry;
            float tzmin1 =   n3.x*invDirz - odirz;
            float txmax1 =   n3.y*invDirx - odirx;
            float tymax1 =   n3.z*invDiry - odiry;
            float tzmax1 =   n3.w*invDirz - odirz;
            float tmin1 = max(max(max(min(tymin1,tymax1),min(txmin1,txmax1)),min(tzmin1,tzmax1)),0.f);
            float tmax1 = min(min(min(max(tymin1,tymax1),max(txmin1,txmax1)),max(tzmin1,tzmax1)), minDistance);
            
            bool traverseChild1 = (tmax1 >= tmin1);

        if(!traverseChild0 && !traverseChild1)
        {

            currentNode = todo[stackptr]; //go back put the stack
            stackptr--;
        }
        else
        {
            float4 n4 = bvh.getValue(tet_bvh_in_tref, currentNode+3); //(leftChild, rightChild, pad,pad)
            int leftChild  = (int)n4.x;
            int rightChild = (int)n4.y;

            currentNode = (traverseChild0) ? leftChild : rightChild;
            if(traverseChild1 && traverseChild0)
            {
                if(tmin0 > tmin1)
                {

                   
                    currentNode = rightChild;
                    stackptr++;
                    todo[stackptr] = leftChild;
                }
                else
                {   
                    stackptr++;
                    todo[stackptr] = rightChild;
                }


            }
        }
        }
        
        if(currentNode < 0 && currentNode != barrier)//check register usage
        {
            
            
            currentNode = -currentNode; //swap the neg address 
            int numTri = (int)tet_bvh_lf_raw.getValue(tet_bvh_lf_tref,currentNode)+1;
            int tetIndex=(int)tet_bvh_lf_raw.getValue(tet_bvh_lf_tref,currentNode+1); /*only one tet per leaf, we can get rid of the entire inner array */
            //cout<<"Checking primitive "<<tetIndex<<" "<< numTri<<endl;
            int hitCount = 0;
            float dist1 = 0;
            float dist2 = 0;
            float scalar1 = 0;
            float scalar2 = 0;
            for(int i=0;i<4;i++) /* Iterate over the triangles in the tetrahedron */
            {        
                     float4 a4 = verts.getValue(tet_verts_tref, (tetIndex*4+i%4)  ); /*Figure out a better way to do this*/
                     float4 b4 = verts.getValue(tet_verts_tref, (tetIndex*4+(1+i)%4));
                     float4 c4 = verts.getValue(tet_verts_tref, (tetIndex*4+(2+i)%4));
                     //cout<<(tetIndex*4+i%4  )<<" "<<(tetIndex*4+(1+i)%4)<<" "<<(tetIndex*4+(2+i)%4)<<endl;
                     //float4 d4 = verts.getValue(tet_verts_tref, ((tetIndex*4+3)+i)%4);
                     //cout<<a4.x<<" "<<a4.y<<" "<<a4.z<<endl;
                     //cout<<b4.x<<" "<<b4.y<<" "<<b4.z<<endl;
                     //cout<<c4.x<<" "<<c4.y<<" "<<c4.z<<endl;
                    eavlVector3 e1( b4.x-a4.x , b4.y-a4.y, b4.z-a4.z );
                    eavlVector3 e2( c4.x-a4.x , c4.y-a4.y, c4.z-a4.z ); 
                    


                    eavlVector3 p;
                    p.x = diry*e2.z - dirz*e2.y;
                    p.y = dirz*e2.x - dirx*e2.z;
                    p.z = dirx*e2.y - diry*e2.x;
                    float dot = e1*p;
                    if(dot != 0.f)
                    {   //cout<<" dot ";
                        dot = 1.f/dot;
                        eavlVector3 t;
                        t.x = ox - a4.x;
                        t.y = oy - a4.y;
                        t.z = oz - a4.z;

                        float u = (t*p)*dot;
                        if(u >= 0.f && u <= 1.f)
                        {//cout<<" u ";
                            eavlVector3 q = t%e1;
                            float v = (dirx*q.x + diry*q.y + dirz*q.z)*dot;
                            if(v >= 0.f && v <= 1.f)  //hits 3 or 1 
                            {//cout<<" v ";
                                float dist = (e2*q)*dot;
                                //if((dist > EPSILON && dist < minDistance) && !(u+v>1) )
                                if((dist < minDistance) && !(u+v>1) )
                                {
                                    float scalar = a4.w*u + b4.w*v + c4.w*(1 - u - v); //lerp
                                    hitCount++;
                                    if(nextSampleDistance == 0) { nextSampleDistance = dist; break; }
                                    if(hitCount == 1)
                                    {
                                      dist1 = dist; //we are looking for two distances  
                                      scalar1 =scalar;
                                    } 
                                    else
                                    {
                                      dist2 = dist;
                                      scalar2 = scalar;  
                                    } 
                                    //minDistance = dist;
                                    //minIndex = triIndex;
                                    //cout<<"Hit t "<<i<<" at tet "<<tetIndex<<endl;
                
                                }
                            }
                        }

                    }
                   
            }
            /* now see if the sample point in within this range */
            if(hitCount == 2)
            {   if(dist1 > dist2)
                {
                    float t = dist1;
                    dist1 = dist2;
                    dist2 = t;
                    t = scalar1;
                    scalar2 = scalar1;
                    scalar1 = t;
                } 
                cout<<"D1 "<<dist1<<" next Sample "<<nextSampleDistance<<" D2 "<<dist2<<endl;
                while (nextSampleDistance >= dist1 && nextSampleDistance <= dist2)
                {
                    cout<<"SAMPLE "<<nextSampleDistance<<" ";
                    nextSampleDistance+=sampleDelta;
                }
            }

            currentNode=todo[stackptr];
            stackptr--;
        }

    }
 distance=minDistance;
 return minIndex;
}

struct RayIntersectFunctor{


    eavlConstArrayV2<float4> verts;
    eavlConstArrayV2<float4> bvh;
    eavlConstArrayV2<float>  bvh_inner;
    primitive_t              primitiveType;
    float                    sampleDelta;

    RayIntersectFunctor(eavlConstArrayV2<float4> *_verts, eavlConstArrayV2<float4> *theBvh,eavlConstArrayV2<float> *_bvh_inner, primitive_t _primitveType, float _sampleDelta)
        :verts(*_verts),
         bvh(*theBvh),
         bvh_inner(*_bvh_inner),
         primitiveType(_primitveType),
         sampleDelta(_sampleDelta)
    {}                                                 
    EAVL_HOSTDEVICE tuple<float,float,float> operator()( tuple<float,float,float,float,float,float> rayTuple){

        int   minHit = -1; 
        float distance;
        eavlVector3 rayOrigin(get<3>(rayTuple),get<4>(rayTuple),get<5>(rayTuple));
        eavlVector3       ray(get<0>(rayTuple),get<1>(rayTuple),get<2>(rayTuple));
        if(primitiveType == TET)
        {
            minHit = getIntersectionTet(ray, rayOrigin,bvh,bvh_inner, verts,INFINITE,distance,sampleDelta);
        } 
        
        
        return tuple<float,float,float>(0,0,0);
    }
};


void eavlVolumeRendererMutator::allocateArrays()
{
	deleteClassPtr(rayDirX);
    deleteClassPtr(rayDirY);
    deleteClassPtr(rayDirZ);

    deleteClassPtr(rayOriginX);
    deleteClassPtr(rayOriginY);
    deleteClassPtr(rayOriginZ);

    deleteClassPtr(r);
    deleteClassPtr(g);
    deleteClassPtr(b);

    deleteClassPtr(indexes);
    deleteClassPtr(mortonIndexes);

    indexes          = new eavlIntArray("indexes",1,size);
    mortonIndexes    = new eavlIntArray("mortonIdxs",1,size);

    rayDirX          = new eavlFloatArray("x",1,size);
    rayDirY          = new eavlFloatArray("y",1,size);
    rayDirZ          = new eavlFloatArray("z",1,size);

    rayOriginX       = new eavlFloatArray("x",1,size);
    rayOriginY       = new eavlFloatArray("y",1,size);
    rayOriginZ       = new eavlFloatArray("z",1,size);

    r                = new eavlFloatArray("r",1,size);
    g                = new eavlFloatArray("b",1,size);
    b                = new eavlFloatArray("g",1,size);

    sizeDirty = false;
}

void eavlVolumeRendererMutator::init()
{
	size = height*width;
	if(sizeDirty) 
    {
        allocateArrays();
        createRays(); //creates the morton ray indexes
    }

    /* Set ray origins to the eye */
    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(indexes), //dummy arg
                                             eavlOpArgs(rayOriginX,rayOriginY,rayOriginZ),
                                             FloatMemsetFunctor3to3(camera.position.x,camera.position.y,camera.position.z)),
                                             "init");
    eavlExecutor::Go();

    /* Copy morton indexes into idxs*/ 
    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(mortonIndexes),
                                             eavlOpArgs(indexes),
                                             FloatMemcpyFunctor1to1()),
                                             "cpy");
    eavlExecutor::Go();

    if(geomDirty) extractGeometry();
}

void eavlVolumeRendererMutator::extractGeometry()
{
    if(verbose) cerr<<"Extracting Geometry"<<endl;
    freeRaw();
    freeTextures();
    //nunTets = scene.getNumTets();
    tet_verts_raw = scene.getTetPtr();
    int tet_bvh_in_size = 0;
    int tet_bvh_lf_size = 0;
    cout<<"Building BVH...."<<endl;
    SplitBVH *testSplit= new SplitBVH(tet_verts_raw, numTets, TET); // 0=triangle
    cout<<"Done building."<<endl;
    testSplit->getFlatArray(tet_bvh_in_size, tet_bvh_lf_size, tet_bvh_in_raw, tet_bvh_lf_raw);
    //if( writeCache) writeBVHCache(tri_bvh_in_raw, tri_bvh_in_size, tri_bvh_lf_raw, tri_bvh_lf_size, bvhCacheName.c_str());
    delete testSplit;

    tet_bvh_in_array   = new eavlConstArrayV2<float4>( (float4*)tet_bvh_in_raw, tet_bvh_in_size/4, tet_bvh_in_tref);
    tet_bvh_lf_array   = new eavlConstArrayV2<float>( tet_bvh_lf_raw, tet_bvh_lf_size, tet_bvh_lf_tref);
    tet_verts_array    = new eavlConstArrayV2<float4>( (float4*) tet_verts_raw, numTets*4, tet_verts_tref);

    geomDirty=false;
}



void eavlVolumeRendererMutator::Execute()
{
    numTets = scene.getNumTets();
    if(numTets == 0 ) 
    {  
        cout<<"No primitives to render. "<<endl;
        return;
    }

    init();
    camera.look = camera.lookat - camera.position;
    //init camera rays
    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(indexes),
                                             eavlOpArgs(rayDirX ,rayDirY, rayDirZ),
                                             RayGenFunctor(width, height, camera.fovx, camera.fovy, camera.look, camera.up, camera.zoom)),
                                             "ray gen");
    eavlExecutor::Go();

    int ttraverse;
    if(verbose) ttraverse = eavlTimer::Start();
    eavlExecutor::SetExecutionMode(eavlExecutor::ForceCPU);
    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(rayDirX,rayDirY,rayDirZ,rayOriginX,rayOriginY,rayOriginZ),
                                             eavlOpArgs(r,g,b),
                                             RayIntersectFunctor(tet_verts_array,tet_bvh_in_array,tet_bvh_lf_array,TET,sampleDelta)),
                                                                                                        "intersect");
    eavlExecutor::Go();
    eavlExecutor::SetExecutionMode(eavlExecutor::ForceGPU);
    if(verbose) cout<<"Traversal   RUNTIME: "<<eavlTimer::Stop(ttraverse,"traverse")<<endl;

}

void eavlVolumeRendererMutator::createRays()
{
    float fwidth=(float)width;
    float fheight=(float)height;
    float  w,h;

    raySort *rayArray= new raySort[size]; // since this is happening every frame it should not be allocated and deleted constantly.
                                          
    for(int i=0; i<size;i++)
    {
        rayArray[i].id=i;
        w = (float)(i%width)/fwidth;
        h = (float) (i/width)/fheight;
        rayArray[i].mortonCode=morton2D(w,h);
    }
    std::sort(rayArray,rayArray+size,spacialCompare);
    cout<<endl;
    for(int i=0; i<size;i++)
    {
        mortonIndexes->SetValue(i, rayArray[i].id);
    }
    delete[] rayArray; 
} 


void eavlVolumeRendererMutator::freeRaw()
{
    
    deleteArrayPtr(tet_verts_raw);
    deleteArrayPtr(tet_bvh_in_raw);
    deleteArrayPtr(tet_bvh_lf_raw);
    cout<<"Free raw"<<endl;

}


void eavlVolumeRendererMutator::freeTextures()
{
    cout<<"Free textures"<<endl;
   if (tet_bvh_in_array != NULL) 
    {
        tet_bvh_in_array->unbind(tet_bvh_in_tref);
        delete tet_bvh_in_array;
        tet_bvh_in_array = NULL;
    }
    if (tet_bvh_lf_array != NULL) 
    {
        tet_bvh_lf_array->unbind(tet_bvh_lf_tref);
        delete tet_bvh_lf_array;
        tet_bvh_lf_array = NULL;
    }
    if (tet_verts_array != NULL) 
    {
        tet_verts_array ->unbind(tet_verts_tref);
        delete tet_verts_array;
        tet_verts_array = NULL;
    }
}
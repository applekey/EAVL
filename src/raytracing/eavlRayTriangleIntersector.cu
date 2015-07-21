#include "eavlRayTriangleIntersector.h"
#include "eavlRayDefines.h"
#include "eavlMapOp.h"
#include "eavlTimer.h"
#include "eavlScatterOp.h"
#include "eavlRTUtil.h"


EAVL_HOSTDEVICE int getIntersectionWoop(const eavlVector3 rayDir,
									    const eavlVector3 rayOrigin, 
									    bool occlusion, 
									    eavlTextureObject<float4> &innerNodes,
                                        eavlTextureObject<int>  &leafNodes, 
                                        eavlTextureObject<float4> &verts,
                                        const float &maxDistance, 
                                        float &distance,
                                        float &minU,
                                        float &minV)
{

    float minDistance = maxDistance;
    int   minIndex    = -1;
    
    float dirx = rayDir.x;
    float diry = rayDir.y;
    float dirz = rayDir.z;

    float invDirx = rcp_safe(dirx);
    float invDiry = rcp_safe(diry);
    float invDirz = rcp_safe(dirz);
    int currentNode;
  
    int todo[64]; //num of nodes to process
    int stackptr = 0;
    int barrier = (int)END_FLAG;
    currentNode = 0;

    todo[stackptr] = barrier;

    float ox = rayOrigin.x;
    float oy = rayOrigin.y;
    float oz = rayOrigin.z;
    float odirx = ox * invDirx;
    float odiry = oy * invDiry;
    float odirz = oz * invDirz;

    while(currentNode != END_FLAG) {

        if(currentNode>-1)
        {

            float4 n1 = innerNodes.getValue(currentNode  ); //(txmin0, tymin0, tzmin0, txmax0)
            float4 n2 = innerNodes.getValue(currentNode+1); //(tymax0, tzmax0, txmin1, tymin1)
            float4 n3 = innerNodes.getValue(currentNode+2); //(tzmin1, txmax1, tymax1, tzmax1)
            
            float txmin0 = n1.x * invDirx - odirx;       
            float tymin0 = n1.y * invDiry - odiry;         
            float tzmin0 = n1.z * invDirz - odirz;
            float txmax0 = n1.w * invDirx - odirx;
            float tymax0 = n2.x * invDiry - odiry;
            float tzmax0 = n2.y * invDirz - odirz;
           
            float tmin0 = max(max(max(min(tymin0,tymax0),min(txmin0,txmax0)),min(tzmin0,tzmax0)),0.f);
            float tmax0 = min(min(min(max(tymin0,tymax0),max(txmin0,txmax0)),max(tzmin0,tzmax0)), minDistance);
            
            bool traverseChild0 = (tmax0 >= tmin0);

             
            float txmin1 = n2.z * invDirx - odirx;       
            float tymin1 = n2.w * invDiry - odiry;
            float tzmin1 = n3.x * invDirz - odirz;
            float txmax1 = n3.y * invDirx - odirx;
            float tymax1 = n3.z * invDiry-  odiry;
            float tzmax1 = n3.w * invDirz - odirz;
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
            float4 n4 = innerNodes.getValue(currentNode+3); 
            int leftChild;
            memcpy(&leftChild, &n4.x,4);
            int rightChild; 
            memcpy(&rightChild, &n4.y, 4);
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
            currentNode = -currentNode - 1; //swap the neg address 
            int numTri = leafNodes.getValue(currentNode)+1;

            for(int i = 1; i < numTri; i++)
            {        
                    int triIndex = leafNodes.getValue(currentNode+i) * 3;
 
                    float4 zCol = verts.getValue(triIndex);

                    float unitOriginZ = -ox * zCol.x  - oy * zCol.y - oz * zCol.z + zCol.w ;
                    float unitDirZ = dirx * zCol.x + diry * zCol.y + dirz * zCol.z;
                    //printf(" %f %f %f %f ",dirx, diry, dirz, zCol.w);
                    unitDirZ = 1.f / unitDirZ;

                    float dist = unitOriginZ * unitDirZ;
                    //printf("Distance %f ", dist);
                    if((dist > EPSILON && dist < minDistance))
                    {   
                        float4 yCol = verts.getValue(triIndex+1);
                        float unitOriginY = ox * yCol.x  + oy * yCol.y + oz * yCol.z + yCol.w ;
                        float unitDirY = dirx * yCol.x + diry * yCol.y + dirz * yCol.z;
                        float v = dist * unitDirY + unitOriginY;

                        if(v >= 0.f)
                        {
                            float4 xCol = verts.getValue(triIndex+2);
                            float unitOriginX = ox * xCol.x  + oy * xCol.y + oz * xCol.z + xCol.w ;
                            float unitDirX = dirx * xCol.x + diry * xCol.y + dirz * xCol.z;
                            float u = dist * unitDirX + unitOriginX;

                            if((u >= 0.f) && ((u+v) <= 1.00002))
                            {
                                minDistance = dist;
                                minIndex = triIndex / 3;
                                minU = u;
                                minV = v;
                                if(occlusion) return minIndex;//or set todo to -1
                            }
                        }

                    }    
                   
            }
            currentNode = todo[stackptr];
            stackptr--;
        }

    }
 distance = minDistance;
 return minIndex;
}

EAVL_HOSTDEVICE int getIntersectionWoopOcculsion(const eavlVector3 rayDir,
									   			 const eavlVector3 rayOrigin, 
									   			 eavlTextureObject<float4> &innerNodes,
                                       			 eavlTextureObject<int>  &leafNodes, 
                                       			 eavlTextureObject<float4> &verts,
                                       			 const float &maxDistance)
{

    float dirx = rayDir.x;
    float diry = rayDir.y;
    float dirz = rayDir.z;

    float invDirx = rcp_safe(dirx);
    float invDiry = rcp_safe(diry);
    float invDirz = rcp_safe(dirz);
    int currentNode;
  
    int todo[64]; //num of nodes to process
    int stackptr = 0;
    int barrier = (int)END_FLAG;
    currentNode = 0;

    todo[stackptr] = barrier;

    float ox = rayOrigin.x;
    float oy = rayOrigin.y;
    float oz = rayOrigin.z;
    float odirx = ox * invDirx;
    float odiry = oy * invDiry;
    float odirz = oz * invDirz;

    while(currentNode != END_FLAG) {

        if(currentNode>-1)
        {

            float4 n1 = innerNodes.getValue(currentNode  ); //(txmin0, tymin0, tzmin0, txmax0)
            float4 n2 = innerNodes.getValue(currentNode+1); //(tymax0, tzmax0, txmin1, tymin1)
            float4 n3 = innerNodes.getValue(currentNode+2); //(tzmin1, txmax1, tymax1, tzmax1)
            
            float txmin0 = n1.x * invDirx - odirx;       
            float tymin0 = n1.y * invDiry - odiry;         
            float tzmin0 = n1.z * invDirz - odirz;
            float txmax0 = n1.w * invDirx - odirx;
            float tymax0 = n2.x * invDiry - odiry;
            float tzmax0 = n2.y * invDirz - odirz;
           
            float tmin0 = max(max(max(min(tymin0,tymax0),min(txmin0,txmax0)),min(tzmin0,tzmax0)),0.f);
            float tmax0 = min(min(min(max(tymin0,tymax0),max(txmin0,txmax0)),max(tzmin0,tzmax0)), maxDistance);
            
            bool traverseChild0 = (tmax0 >= tmin0);

             
            float txmin1 = n2.z * invDirx - odirx;       
            float tymin1 = n2.w * invDiry - odiry;
            float tzmin1 = n3.x * invDirz - odirz;
            float txmax1 = n3.y * invDirx - odirx;
            float tymax1 = n3.z * invDiry-  odiry;
            float tzmax1 = n3.w * invDirz - odirz;
            float tmin1 = max(max(max(min(tymin1,tymax1),min(txmin1,txmax1)),min(tzmin1,tzmax1)),0.f);
            float tmax1 = min(min(min(max(tymin1,tymax1),max(txmin1,txmax1)),max(tzmin1,tzmax1)), maxDistance);
            
            bool traverseChild1 = (tmax1 >= tmin1);

        if(!traverseChild0 && !traverseChild1)
        {

            currentNode = todo[stackptr]; //go back put the stack
            stackptr--;
        }
        else
        {
            float4 n4 = innerNodes.getValue(currentNode+3); 
            int leftChild;
            memcpy(&leftChild, &n4.x,4);
            int rightChild; 
            memcpy(&rightChild, &n4.y, 4);
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
            currentNode = -currentNode - 1; //swap the neg address 
            int numTri = leafNodes.getValue(currentNode)+1;

            for(int i = 1; i < numTri; i++)
            {        
                    int triIndex = leafNodes.getValue(currentNode+i) * 3;
                    float4 zCol = verts.getValue(triIndex);
                    float unitOriginZ = -ox * zCol.x  - oy * zCol.y - oz * zCol.z + zCol.w ;
                    float unitDirZ = dirx * zCol.x + diry * zCol.y + dirz * zCol.z;
                    unitDirZ = 1.f / unitDirZ;

                    float dist = unitOriginZ * unitDirZ;
                    if((dist > EPSILON && dist < maxDistance))
                    {   
                        float4 yCol = verts.getValue(triIndex+1);
                        float unitOriginY = ox * yCol.x  + oy * yCol.y + oz * yCol.z + yCol.w ;
                        float unitDirY = dirx * yCol.x + diry * yCol.y + dirz * yCol.z;
                        float v = dist * unitDirY + unitOriginY;

                        if(v >= 0.f)
                        {
                            float4 xCol = verts.getValue(triIndex+2);
                            float unitOriginX = ox * xCol.x  + oy * xCol.y + oz * xCol.z + xCol.w ;
                            float unitDirX = dirx * xCol.x + diry * xCol.y + dirz * xCol.z;
                            float u = dist * unitDirX + unitOriginX;

                            if((u >= 0.f) && ((u+v) <= 1.00002))
                            {
                                return 1; //ray is occluded
                            }
                        }

                    }    
                   
            }
            currentNode = todo[stackptr];
            stackptr--;
        }

    }
 
 return -1; //clear path
}

struct UnitMultipleDistancesTriangleDepthFunctor{


    eavlTextureObject<float4> verts;
    eavlTextureObject<float4> innerNodes;
    eavlTextureObject<int>  leafNodes;

    UnitMultipleDistancesTriangleDepthFunctor(eavlTextureObject<float4> *_verts,
    						 				  eavlTextureObject<float4> *_innerNodes,
                                              eavlTextureObject<int>  *_leafNodes)
        :verts(*_verts),
         innerNodes(*_innerNodes),
         leafNodes(*_leafNodes)
    {}                                                 
    EAVL_HOSTDEVICE tuple<int,float, float, float> operator()( tuple<float,float,float,float,float,float,float> rayTuple){
       
        float distance;
        float maxDistance = get<6>(rayTuple);
        eavlVector3 rayOrigin(get<0>(rayTuple),get<1>(rayTuple),get<2>(rayTuple));
        eavlVector3       ray(get<3>(rayTuple),get<4>(rayTuple),get<5>(rayTuple));
        float u = 0.f;
        float v = 0.f;
        int minHit = getIntersectionWoop(ray,
        							 	 rayOrigin, 
        							 	 false,
        							 	 innerNodes,
        							 	 leafNodes, 
        							 	 verts,
        							 	 maxDistance,
        							 	 distance,
                                         u,
                                         v);
        
		return tuple<int,float, float, float>(minHit, distance, u, v);
    }
};

struct UnitSingleDistanceTriangleDepthFunctor{


    eavlTextureObject<float4> verts;
    eavlTextureObject<float4> innerNodes;
    eavlTextureObject<int>  leafNodes;
    int maxDistance;

    UnitSingleDistanceTriangleDepthFunctor(eavlTextureObject<float4> *_verts,
    						 				  eavlTextureObject<float4> *_innerNodes,
                                              eavlTextureObject<int>  *_leafNodes,
                                              int _maxDistance)
        :verts(*_verts),
         innerNodes(*_innerNodes),
         leafNodes(*_leafNodes),
         maxDistance(_maxDistance)

 
    {}                                                 
    EAVL_HOSTDEVICE tuple<int,float,float,float> operator()( tuple<float,float,float,float,float,float> rayTuple){
       
        float distance;
        eavlVector3 rayOrigin(get<0>(rayTuple),get<1>(rayTuple),get<2>(rayTuple));
        eavlVector3       ray(get<3>(rayTuple),get<4>(rayTuple),get<5>(rayTuple));
        //printf(" %f %f %f " ,ray.x,ray.y,ray.z);
        float u = 0.f;
        float v = 0.f;
        int minHit = getIntersectionWoop(ray,
        							 	 rayOrigin, 
        							 	 false,
        							 	 innerNodes,
        							 	 leafNodes, 
        							 	 verts,
        							 	 maxDistance,
        							 	 distance,
                                         u,
                                         v);
        if(minHit == -1) distance = INFINITE;
		return tuple<int,float,float,float>(minHit, distance,u,v);
 
    }
};

struct UnitShadowFunctor{
    eavlTextureObject<float4> verts;
    eavlTextureObject<float4> innerNodes;
    eavlTextureObject<int>  leafNodes;
    eavlVector3				lightPosition;

    UnitShadowFunctor(eavlTextureObject<float4> *_verts,
    				  eavlTextureObject<float4> *_innerNodes,
                      eavlTextureObject<int>  *_leafNodes,
                      eavlVector3 &_lightPosition)
        :verts(*_verts),
         innerNodes(*_innerNodes),
         leafNodes(*_leafNodes),
         lightPosition(_lightPosition)

 
    {}                                                 
    EAVL_HOSTDEVICE tuple<int> operator()( tuple<float,float,float> rayTuple){
       
 
        eavlVector3 rayOrigin(get<0>(rayTuple),get<1>(rayTuple),get<2>(rayTuple));
        eavlVector3 rayDir = lightPosition - rayOrigin;
        float maxDistance = sqrt(rayDir*rayDir);
        int minHit = getIntersectionWoopOcculsion(rayDir,
        							 	 		  rayOrigin,
        							 	 		  innerNodes,
        							 	 		  leafNodes, 
        							 	 		  verts,
        							 	 		  maxDistance);
		return tuple<int>(minHit);
 
    }
};

EAVL_HOSTDEVICE float testFunction(const eavlTextureObject<float4> *tt)
{ 
    return tt->getValue(0).x;
}

struct testfunctor{


    eavlTextureObject<float4> verts;
   

    testfunctor(eavlTextureObject<float4> *_verts)
        :verts(*_verts)

 
    {}                                                 
    EAVL_HOSTDEVICE tuple<float> operator()( tuple<float> rayTuple){
       
        float distance = get<0>(rayTuple);
        printf("ID inside %llu \n", verts.textureObjectId);
        distance *= verts.getValue(0).x;

          
        return tuple<float>( distance);
 
    }
};


EAVL_HOSTONLY void eavlRayTriangleIntersector::intersectionDepth(const eavlRay *rays, 
					   								   	  		 const int &maxDistance, 
											  		      		 const eavlRayTriangleGeometry *geometry)
{
	eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(rays->rayOriginX,
														rays->rayOriginY,
														rays->rayOriginZ,
														rays->rayDirX,
														rays->rayDirY,
														rays->rayDirZ),
                                             eavlOpArgs(rays->hitIdx,
                                             			rays->distance,
                                                        rays->alpha,
                                                        rays->beta),
                                             UnitSingleDistanceTriangleDepthFunctor(geometry->vertices,
                                             										geometry->bvhInnerNodes,
                                             										geometry->bvhLeafNodes,
                                             										maxDistance)),
                                             "Intersect");
    eavlExecutor::Go();
}

EAVL_HOSTONLY void eavlRayTriangleIntersector::intersectionDepth(const eavlRay *rays, 
													      		 eavlFloatArray *maxDistances,
													      		 const eavlRayTriangleGeometry *geometry)
{

	eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(rays->rayOriginX,
														rays->rayOriginY,
														rays->rayOriginZ,
														rays->rayDirX,
														rays->rayDirY,
														rays->rayDirZ,
														maxDistances),
                                             eavlOpArgs(rays->hitIdx,
                                             			rays->distance,
                                                        rays->alpha,
                                                        rays->beta),
                                             UnitMultipleDistancesTriangleDepthFunctor(geometry->vertices,
                                             										  geometry->bvhInnerNodes,
                                             										  geometry->bvhLeafNodes)),
                                             "Intersect");
    eavlExecutor::Go();
}

EAVL_HOSTONLY void eavlRayTriangleIntersector::intersectionShadow(const eavlFullRay *rays, 
													      		 eavlIntArray *hits,
													      		 eavlVector3 &lightPosition,
													      		 const eavlRayTriangleGeometry *geometry)
{

	eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(rays->intersectionX,
														rays->intersectionY,
														rays->intersectionZ),
                                             eavlOpArgs(hits),
                                             UnitShadowFunctor(geometry->vertices,
                                             				   geometry->bvhInnerNodes,
                                             				   geometry->bvhLeafNodes,
                                             				   lightPosition)),
                                             "Intersect");
    eavlExecutor::Go();
}

EAVL_HOSTONLY void eavlRayTriangleIntersector::testIntersections(const eavlRay *rays, 
									  					  	     const int &maxDistance, 
									  					  	     const eavlRayTriangleGeometry *geometry,
									  				      		 const int &warmUpRounds,
									  					  		 const int &testRounds,
									  					  		 eavlRayCamera *cam)
{
	int height = cam->getHeight();
	int width = cam->getWidth(); 
	int size = width * height;

	eavlIntArray    *dummy= new eavlIntArray("",1,size);
    eavlFloatArray  *dummyFloat= new eavlFloatArray("",1,size);
    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(rays->rayOriginX),
                                                 eavlOpArgs(
                                                            dummyFloat),
                                                testfunctor(geometry->vertices),1),
                                                "TestFunc");
        eavlExecutor::Go();

    cout<<"Warming up "<<warmUpRounds<<" rounds."<<endl;
    int warm = eavlTimer::Start(); 

    for(int i = 0; i < warmUpRounds; i++)
    {
    	eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(rays->rayOriginX,
															rays->rayOriginY,
															rays->rayOriginZ,
															rays->rayDirX,
															rays->rayDirY,
															rays->rayDirZ),
                                            	 eavlOpArgs(dummy,
                                             				dummyFloat,
                                                            rays->alpha,
                                                            rays->beta),
                                             	UnitSingleDistanceTriangleDepthFunctor(geometry->vertices,
                                             										   geometry->bvhInnerNodes,
                                             										   geometry->bvhLeafNodes,
                                             										   INFINITE)),
                                             	"Intersect");
    	eavlExecutor::Go();
    }

    float rayper=size/(eavlTimer::Stop(warm,"warm")/(float)warmUpRounds);
    cout << "Warm up "<<rayper/1000000.f<< " Mrays/sec"<<endl;

    int test = eavlTimer::Start();

    for(int i = 0; i < testRounds; i++)
    {
    	eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(rays->rayOriginX,
															rays->rayOriginY,
															rays->rayOriginZ,
															rays->rayDirX,
															rays->rayDirY,
															rays->rayDirZ),
                                            	 eavlOpArgs(dummy,
                                             				dummyFloat,
                                                            rays->alpha,
                                                            rays->beta),
                                             	UnitSingleDistanceTriangleDepthFunctor(geometry->vertices,
                                             										   geometry->bvhInnerNodes,
                                             										   geometry->bvhLeafNodes,
                                             										   INFINITE)),
                                             	"Intersect");
    	eavlExecutor::Go();
    }

    rayper=size/(eavlTimer::Stop(test,"test")/(float)testRounds);
    cout << "# "<<rayper/1000000.f<<endl;

    eavlExecutor::AddOperation(new_eavlMapOp(eavlOpArgs(rays->rayOriginX,
														rays->rayOriginY,
														rays->rayOriginZ,
														rays->rayDirX,
														rays->rayDirY,
														rays->rayDirZ),
                                             eavlOpArgs(rays->hitIdx,
                                             			rays->distance,
                                                        rays->alpha,
                                                        rays->beta),
                                             	UnitSingleDistanceTriangleDepthFunctor(geometry->vertices,
                                             										   geometry->bvhInnerNodes,
                                             										   geometry->bvhLeafNodes,
                                             										   INFINITE)),
                                             	"Intersect");
    eavlExecutor::Go();

 
    float maxDepth = 0;
    float minDepth = INFINITE;
    //for(int i=0; i< size; i++) if(rays->hitIdx->GetValue(i) != -1) cout<<"HIT";
    float acc = 0.f;
    for(int i=0; i< size; i++)
    {
        acc += rays->distance->GetValue(i);
        if( rays->distance->GetValue(i) == INFINITE) 
        {   
                rays->distance->SetValue(i,0);
        }
        else
        {

            maxDepth= max(rays->distance->GetValue(i), maxDepth);  
            minDepth= max(0.f,min(minDepth, rays->distance->GetValue(i)));//??
        }
        
    }
    cout<<"Total : "<<(int)acc<<endl; 
    cout<<"Depths "<<minDepth<<" "<<maxDepth<<endl;
    maxDepth = maxDepth - minDepth;

    for(int i = 0; i < size; i++) rays->distance->SetValue(i, (rays->distance->GetValue(i) - minDepth) / maxDepth);

    eavlExecutor::AddOperation(new_eavlScatterOp(eavlOpArgs(rays->distance),
                                                 eavlOpArgs(dummyFloat),
                                                 eavlOpArgs(cam->getPixelIndexes())),
                                                "scatter");
    eavlExecutor::Go();

    writeBMP(cam->getHeight(),cam->getWidth(),dummyFloat,dummyFloat,dummyFloat,"depth.bmp");

    delete dummyFloat;
    delete dummy;

}

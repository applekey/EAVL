#include "eavlCUDA.h"
#include "eavlImporterFactory.h"
#include "eavlIsosurfaceFilter.h"
#include "eavlExecutor.h"
#include "eavlSimpleVRMutator.h"
#include "eavlTransferFunction.h"
#include "eavlView.h"
#include <string.h>
#include <sys/time.h>
#include <ctime>
#include <sstream>
#include <eavlRTUtil.h>
#include "eavlImporterFactory.h"
#include "eavlCellSetExplicit.h"
#include "eavlCell.h"
#ifdef HAVE_OPENMP
#include <omp.h>
#endif

#include "TF.h"
#include "cameraRot.h"

int main(int argc, char *argv[])
{   

    try

    { 
        eavlView view;
        const string filename = "/home/roba/Data/lulesh/lulesh_c4525_speed_tet.vtk";
        string outFilename = "lulesh";
        int height = 500;
        int width = 500;
        int samples = 1000;
        int numPasses = 1;
        int meshIdx = 0;
        int  cellSetIdx = 0;
        int  fieldIdx = 1;
        float opactiyFactor = 1;
        double myRad = 0.0;//0.2617993878;
        double myZoomVal= 1.94856;//34;
        bool verbose = false;
     
        eavlExecutor::SetExecutionMode(eavlExecutor::ForceCPU);
        eavlSimpleVRMutator *vrenderer= new eavlSimpleVRMutator();
        vrenderer->setVerbose(verbose);
        //&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&
        // HAS TO SET THIS ADDED FOR LC SAMPLING
        vrenderer->setSampleLCFlag(1);
        vrenderer->scene->normalizedScalars(true);
        vrenderer->setNumPasses(numPasses);
        vrenderer->setNumSamples(samples);

        vrenderer->setDataName(outFilename);
        vrenderer->setOpacityFactor(opactiyFactor);    
        eavlImporter *importer = eavlImporterFactory::GetImporterForFile(filename);
        

        //--------------------------Getting mesh info-----------------------------------------------
        vector<string> meshlist = importer->GetMeshList();
        int msize = meshlist.size();
        int domainindex = 0;

        
        eavlDataSet *data = importer->GetMesh(meshlist.at(meshIdx), domainindex);
        
        int numCellSets = data->GetNumCellSets();
        eavlCellSetExplicit* cellSet = (eavlCellSetExplicit*) data->GetCellSet(cellSetIdx);


        vector<string> fieldList = importer->GetFieldList(meshlist.at(meshIdx));
        int numfields = fieldList.size();
        for(int i = 0; i < numfields; i++)
            {
                cout<<"Index "<<i<<" "<<fieldList.at(i)<<endl;
            }
        cout<<"Using field      : "<<fieldList.at(fieldIdx)<<endl;
        data->AddField(importer->GetField(fieldList.at(fieldIdx), meshlist.at(meshIdx), domainindex));
        //------------------------Walk the mesh and get the data--------------------------------
        int vertexIds[4];
        int numCells = cellSet->GetNumCells();
        cout<<"Processing  "<<numCells<<" cells"<<endl;
        int nIds = 0;
        int numTets = 0;
        for(int i = 0; i < numCells; i++)
        {
            if(cellSet->GetCellNodes(i).type != EAVL_TET) continue;
            numTets++;
            cellSet->GetConnectivity(EAVL_NODES_OF_CELLS).GetElementComponents(i,nIds,vertexIds);
            
            eavlVector3 v[4];
            float scalars[4];

            for(int j = 0; j < 4; j++)
            {
                v[j].x = ((eavlFloatArray*)(data->GetField("xcoord")->GetArray()))->GetValue(vertexIds[j]);
                v[j].y = ((eavlFloatArray*)(data->GetField("ycoord")->GetArray()))->GetValue(vertexIds[j]);
                v[j].z = ((eavlFloatArray*)(data->GetField("zcoord")->GetArray()))->GetValue(vertexIds[j]);
                scalars[j] = ((eavlFloatArray*)(data->GetField(fieldList.at(fieldIdx))->GetArray()))->GetValue(vertexIds[j]);
            }// adding tet

            vrenderer->scene->addTet(v[0], v[1], v[2], v[3], scalars[0], scalars[1], scalars[2], scalars[3]);
        }// for cell
        
        //data->PrintSummary(cout);
        

        //setup the view
        BBox bbox = vrenderer->scene->getSceneBBox();

        eavlPoint3 center = eavlPoint3((bbox.max.x + bbox.min.x) / 2,
                                       (bbox.max.y + bbox.min.y) / 2,
                                       (bbox.max.z + bbox.min.z) / 2);

    cerr<<"Set TF\n";
    eavlTransferFunction myTransfer("IsoL");
     float pos;
    for(int i=0; i<256; i++)
    {
        pos = i/256.0;
        myTransfer.AddAlphaControlPoint(pos,opac4[i]/255.0);
    }

        float *ctable = new float[1024 *4];
        myTransfer.GetTransferFunction(1024, ctable);
        vrenderer->setColorMap4f(ctable, 1024);
        
    
            eavlMatrix4x4 *myMatrix = new eavlMatrix4x4();
            myMatrix->CreateIdentity();
            view.viewtype = eavlView::EAVL_VIEW_3D;
            view.h = height;
            view.w = width;
            float ds_size = vrenderer->scene->getSceneMagnitude();
            view.size = ds_size;
            cerr<<"ds_size "<<ds_size<<"\n";
            view.view3d.perspective = true;
            //-0.01640186701923537 -0.03843155483139624 0.9991266157757609
            view.view3d.up   = eavlVector3(0,-1,0);
            view.view3d.fov  = 0.5;
            view.view3d.xpan = 0;
            view.view3d.ypan = 0;
            view.view3d.zoom = 1.0;
            view.view3d.at   = center;
            cerr<<"Center "<<center[0]<<" "<<center[1]<<" "<<center[2]<<"\n";
            cerr<<"Zoom Val"<<myZoomVal<<"\n";
            float fromDist  = 5.0;//myZoomVal/2;
            cerr<<"fromDist "<<fromDist<<"\n";
            myMatrix->CreateRotateZ(myRad);
            eavlPoint3 mypoint = view.view3d.at+ eavlVector3(-fromDist/2,0,-fromDist);//eavlPoint3(fromDist,0,fromDist);
            eavlPoint3 rotPoint = myMatrix->operator*(mypoint);
            view.view3d.from =  rotPoint;
            view.view3d.nearplane = 0;  
            view.view3d.farplane =  1;
            view.SetupMatrices();
       
            //extract bounding box and project
            eavlPoint3 mins(bbox.min.x,bbox.min.y,bbox.min.z);
            eavlPoint3 maxs(bbox.max.x,bbox.max.y,bbox.max.z);

            mins = view.V * mins;
            maxs = view.V * maxs;

            //squeeze near and far plane to extract max samples
            view.view3d.nearplane = -maxs.z - 5; 
            view.view3d.farplane =  -mins.z + 2; 
            view.SetupMatrices();
            //cout<<view.P<<" \n"<<view.V<<endl;
            vrenderer->setView(view);

          cerr<<"Rendering to Framebuffer\n";
            for(int i=0; i<1;i++)
            {
                vrenderer->Execute();
            }


            //eavlFloatArray* testfloatArr = vrenderer->myFloatrays;
            //cerr<<"Partial array has "<<testfloatArr->GetNumberOfTuples()<<" components\n";
            //for(int i=0; i<testfloatArr->GetNumberOfTuples();i++)
            writeFrameBufferBMP(height, width, vrenderer->getRealFrameBuffer(), outFilename.c_str());
            cerr<<"Done writing BMP\n";


    }// try
    catch (const eavlException &e)
    {
        cerr << e.GetErrorText() << endl;
        return 1;
    }

    return 0;
}// main

//Camera info for hardy Data
//------------------------------
			double myZoomVal= 34;

            eavlMatrix4x4 *myMatrix = new eavlMatrix4x4();
            myMatrix->CreateIdentity();
            view.viewtype = eavlView::EAVL_VIEW_3D;
            view.h = height;
            view.w = width;
            float ds_size = vrenderer->scene->getSceneMagnitude();
            view.size = ds_size;
            view.view3d.perspective = true;
            view.view3d.up   = eavlVector3(0,0,1);
            view.view3d.fov  = 0.5;
            view.view3d.xpan = 0;
            view.view3d.ypan = 0;
            view.view3d.zoom = 1.0;
            view.view3d.at   = center;
            cerr<<"Zoom Val"<<myZoomVal<<"\n";
            float fromDist  =  myZoomVal;
            myMatrix->CreateRotateX(myRad);
            eavlPoint3 mypoint = eavlPoint3(fromDist,0,fromDist);
            eavlPoint3 rotPoint = myMatrix->operator*(mypoint);
            view.view3d.from = rotPoint;
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
            cout<<view.P<<" \n"<<view.V<<endl;
            vrenderer->setView(view);


//--------------------------------------------
//Camra info for lulesh Data
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
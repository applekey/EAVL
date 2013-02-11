// Copyright 2010-2013 UT-Battelle, LLC.  See LICENSE.txt for more information.
#ifndef EAVL_2D_WINDOW_H
#define EAVL_2D_WINDOW_H

#include "eavlWindow.h"
#include <eavlTextAnnotation.h>
#include <eavlColorBarAnnotation.h>
#include <eavl2DAxisAnnotation.h>
#include <eavl2DFrameAnnotation.h>
#include "eavlScene.h"

class eavl2DWindow : public eavlWindow
{
  public:
    ///\todo: HACK:
    eavlScene *scene;
  protected:
    eavlColorBarAnnotation *colorbar;
    eavl2DAxisAnnotation *haxis, *vaxis;
    eavl2DFrameAnnotation *frame;
  public:
    eavl2DWindow() : eavlWindow()
    {
        view.vl = -.7;
        view.vr = +.7;
        view.vb = -.7;
        view.vt = +.7;

        colorbar = new eavlColorBarAnnotation(this);
        haxis = new eavl2DAxisAnnotation(this);
        vaxis = new eavl2DAxisAnnotation(this);
        frame = new eavl2DFrameAnnotation(this);
    }
    virtual void Paint()
    {
        view.SetupMatrices();

        glClearColor(0.0, 0.15, 0.3, 1.0);
        glClear( GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT );

        // render the plots
        scene->Render(view);

        glDisable(GL_DEPTH_TEST);

        float vl, vr, vt, vb;
        view.GetRealViewport(vl,vr,vb,vt);
        frame->SetExtents(vl,vr, vb,vt);
        frame->SetColor(eavlColor(.7,.7,.7));
        frame->Render(view);

        haxis->SetColor(eavlColor::white);
        haxis->SetScreenPosition(vl,vb, vr,vb);
        haxis->SetRangeForAutoTicks(view.view2d.l, view.view2d.r);
        haxis->SetMajorTickSize(0, .05, 1.0);
        haxis->SetMinorTickSize(0, .02, 1.0);
        haxis->SetLabelAnchor(0.5, 1.0);
        haxis->Render(view);

        vaxis->SetColor(eavlColor::white);
        vaxis->SetScreenPosition(vl,vb, vl,vt);
        vaxis->SetRangeForAutoTicks(view.view2d.b, view.view2d.t);
        vaxis->SetMajorTickSize(.05 / view.windowaspect, 0, 1.0);
        vaxis->SetMinorTickSize(.02 / view.windowaspect, 0, 1.0);
        vaxis->SetLabelAnchor(1.0, 0.47);
        vaxis->Render(view);

        if (scene->plots[0].pcRenderer)
        {
            double vmin, vmax;
            ((eavlPseudocolorRenderer*)(scene->plots[0].pcRenderer))->GetLimits(vmin, vmax);
            colorbar->SetAxisColor(eavlColor::white);
            colorbar->SetRange(vmin, vmax, 5);
            colorbar->SetColorTable(scene->plots[0].colortable);
            colorbar->Render(view);
        }

        glFinish();
    }
};

#endif

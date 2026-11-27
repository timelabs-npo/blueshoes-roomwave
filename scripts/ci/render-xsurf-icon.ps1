param([string]$Output = (Join-Path $PSScriptRoot '../../apps/ios/Roomwave/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
if ($PSVersionTable.PSEdition -eq 'Core') { $refs = [AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES').Split([IO.Path]::PathSeparator) } else { $refs = @('System.Drawing') }
Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class XsurfIcon {
  static Color C(int r,int g,int b){return Color.FromArgb(r,g,b);}
  static PointF P(float x,float y){return new PointF(x,y);}
  static LinearGradientBrush B(float x1,float y1,float x2,float y2,Color a,Color b){
    return new LinearGradientBrush(P(x1,y1),P(x2,y2),a,b);
  }
  static void Line(Graphics g, GraphicsPath p, Color c,float width){
    using(var pen=new Pen(c,width)){pen.StartCap=LineCap.Round;pen.EndCap=LineCap.Round;g.DrawPath(pen,p);}
  }
  public static void Render(string output) {
    using(var bitmap = new Bitmap(1024,1024,PixelFormat.Format24bppRgb))
    using(var g=Graphics.FromImage(bitmap)) {
      g.SmoothingMode=SmoothingMode.AntiAlias;
      using(var b=B(0,0,1024,1024,C(16,23,51),C(14,7,25))) g.FillRectangle(b,0,0,1024,1024);
      for(int i=12;i>=1;i--) {
        var r=145+i*12;
        using(var b=new SolidBrush(Color.FromArgb(5,255,92,75))) g.FillEllipse(b,683-r,379-r,2*r,2*r);
      }
      using(var sun=B(660,230,698,520,C(255,212,118),C(247,76,108))) {
        g.FillEllipse(sun,544,239,278,278);
      }
      var state=808;
      for(int i=0;i<143;i++){
        state=(state*48271)&int.MaxValue; var x=90+state%850;
        state=(state*48271)&int.MaxValue; var y=87+state%780;
        if((x-683)*(x-683)+(y-379)*(y-379)<155*155)continue;
        var radius=state%5==0?2f:1f;
        using(var b=new SolidBrush(Color.FromArgb(28+state%60,255,191,153)))g.FillEllipse(b,x,y,radius,radius);
      }
      using(var wave=new GraphicsPath()) {
        wave.StartFigure();
        wave.AddBezier(177,650,304,713,426,633,529,523);
        wave.AddBezier(529,523,636,402,751,357,871,409);
        wave.AddBezier(871,409,729,381,649,523,609,593);
        wave.AddBezier(609,593,502,785,304,827,177,650);
        wave.CloseFigure();
        using(var b=B(206,690,791,435,C(5,112,175),C(123,255,220)))g.FillPath(b,wave);
        Line(g,wave,Color.FromArgb(38,122,248,235),9);
      }
      using(var crest=new GraphicsPath()){
        crest.AddBezier(222,656,335,698,437,633,540,522);
        crest.AddBezier(540,522,633,422,721,388,804,402);
        using(var gradient=B(100,740,920,325,C(42,179,223),C(232,255,240)))
        using(var p=new Pen(gradient,12)){
          p.StartCap=LineCap.Round;p.EndCap=LineCap.Round;g.DrawPath(p,crest);
        }
      }
      using(var ribbon=new GraphicsPath()){
        ribbon.AddBezier(239,462,348,419,451,464,519,537);
        ribbon.AddBezier(519,537,583,605,656,652,776,637);
        Line(g,ribbon,Color.FromArgb(28,249,128,113),31);
        Line(g,ribbon,C(241,111,114),9);
      }
      using(var foil=new GraphicsPath()){
        foil.AddPolygon(new[]{P(586,467),P(722,344),P(751,335),P(746,360),P(629,486),P(597,500)});
        using(var b=B(586,500,748,335,C(116,245,216),C(255,249,192)))g.FillPath(b,foil);
      }
      using(var p=new Pen(C(126,202,207),3)){
        g.DrawLine(p,136,136,172,136);g.DrawLine(p,136,136,136,172);
        g.DrawLine(p,888,852,888,888);g.DrawLine(p,852,888,888,888);
      }
      bitmap.Save(output,ImageFormat.Png);
    }
  }
}
'@
[XsurfIcon]::Render([IO.Path]::GetFullPath($Output))

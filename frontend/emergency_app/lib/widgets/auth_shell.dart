import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ErasMark extends StatelessWidget {
  const ErasMark({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: compact ? 39 : 46, height: compact ? 39 : 46, decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), gradient: const LinearGradient(colors: [Color(0xFF07A987), Color(0xFF22C9B6)]), boxShadow: [BoxShadow(color: const Color(0xFF0EB7A0).withValues(alpha: dark ? .32 : .18), blurRadius: 18)]), child: const Icon(Icons.health_and_safety_rounded, color: Colors.white, size: 27)),
      const SizedBox(width: 12),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('ERAS', style: TextStyle(fontSize: compact ? 22 : 26, height: 1, fontWeight: FontWeight.w900, letterSpacing: 1.4, color: dark ? Colors.white : AppColors.text)),
        const SizedBox(height: 4),
        Text('Emergency Resource Allocation System', style: TextStyle(fontSize: compact ? 9 : 10.5, color: dark ? const Color(0xFF9EB0C6) : AppColors.textDim)),
      ]),
    ]);
  }
}

class ThemeSwitch extends StatelessWidget {
  const ThemeSwitch({super.key});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(button: true, label: dark ? 'Switch to light theme' : 'Switch to dark theme', child: InkWell(
      onTap: ThemeController.toggle,
      borderRadius: BorderRadius.circular(24),
      child: AnimatedContainer(duration: const Duration(milliseconds: 250), width: 76, height: 38, padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: dark ? const Color(0xFF142A43) : Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: dark ? const Color(0xFF31506E) : AppColors.border), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 12)]), child: Stack(children: [
        AnimatedAlign(duration: const Duration(milliseconds: 250), alignment: dark ? Alignment.centerRight : Alignment.centerLeft, child: Container(width: 28, height: 28, decoration: BoxDecoration(shape: BoxShape.circle, color: dark ? const Color(0xFF236BDC) : const Color(0xFFFFF0C2)))),
        const Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.light_mode_rounded, size: 16, color: Color(0xFFF5A623)))),
        const Align(alignment: Alignment.centerRight, child: Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.dark_mode_rounded, size: 16, color: Color(0xFFBBD3F8)))),
      ])),
    ));
  }
}

class AuthShell extends StatelessWidget {
  const AuthShell({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(body: AnimatedContainer(duration: const Duration(milliseconds: 350), decoration: BoxDecoration(gradient: dark
      ? const RadialGradient(center: Alignment(-.35, -.25), radius: 1.25, colors: [Color(0xFF102B42), Color(0xFF071321), Color(0xFF050E19)])
      : const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFFFFF), Color(0xFFF4F8FC), Color(0xFFEDF4F9)])), child: SafeArea(child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 1050;
        return Stack(children: [
          Positioned.fill(child: CustomPaint(painter: _GridPainter(dark))),
          if (wide) Row(children: [Expanded(flex: 11, child: _StoryPanel(dark: dark)), Expanded(flex: 9, child: Center(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(32, 82, 32, 38), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: child))))])
          else SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 74, 20, 32), child: Column(children: [const Align(alignment: Alignment.centerLeft, child: ErasMark(compact: true)), const SizedBox(height: 25), ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: child), const SizedBox(height: 32), if (c.maxWidth >= 650) const SizedBox(height: 340, child: _NetworkVisual())])),
          const Positioned(top: 18, right: 22, child: ThemeSwitch()),
        ]);
      }))));
  }
}

class _StoryPanel extends StatelessWidget {
  const _StoryPanel({required this.dark}); final bool dark;
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(54, 34, 30, 30), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const ErasMark(), const Spacer(),
    Text('Right Resource.\nRight Place.', style: TextStyle(fontSize: 48, height: 1.08, letterSpacing: -1.5, fontWeight: FontWeight.w900, color: dark ? Colors.white : AppColors.text)),
    Text('Right Time.', style: const TextStyle(fontSize: 48, height: 1.12, letterSpacing: -1.5, fontWeight: FontWeight.w900, color: Color(0xFF12B99D))),
    const SizedBox(height: 16), Text('Smarter coordination. Faster response.\nBetter outcomes for every emergency.', style: TextStyle(fontSize: 15, height: 1.55, color: dark ? const Color(0xFF9EB0C6) : AppColors.textDim)),
    const SizedBox(height: 15), const Expanded(flex: 5, child: _NetworkVisual()), const SizedBox(height: 10),
    Wrap(spacing: 9, runSpacing: 9, children: const [_Metric(icon: Icons.inventory_2_outlined, title: 'Resource Availability', value: 'Live'), _Metric(icon: Icons.emergency_outlined, title: 'Active Requests', value: 'Tracked'), _Metric(icon: Icons.groups_outlined, title: 'Responder Network', value: 'Connected'), _Metric(icon: Icons.hub_outlined, title: 'Coordination', value: 'Real-time')]),
  ]));
}

class _Metric extends StatelessWidget { const _Metric({required this.icon, required this.title, required this.value}); final IconData icon; final String title,value; @override Widget build(BuildContext context) { final dark=Theme.of(context).brightness==Brightness.dark; return Container(width: 145, padding: const EdgeInsets.all(11), decoration: BoxDecoration(color: dark ? const Color(0x99122439) : Colors.white.withValues(alpha:.9), borderRadius: BorderRadius.circular(12), border: Border.all(color: dark ? const Color(0xFF29445F) : AppColors.border)), child: Row(children:[Icon(icon,size:19,color:const Color(0xFF10B99D)),const SizedBox(width:8),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(value,style:TextStyle(fontSize:11,fontWeight:FontWeight.w800,color:dark?Colors.white:AppColors.text)),Text(title,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(fontSize:8.5,color:dark?const Color(0xFF90A4BA):AppColors.textDim))]))])); }}

class _NetworkVisual extends StatelessWidget { const _NetworkVisual(); @override Widget build(BuildContext context) => LayoutBuilder(builder:(context,c)=>CustomPaint(size:Size(c.maxWidth,c.maxHeight),painter:_NetworkPainter(Theme.of(context).brightness==Brightness.dark))); }
class _NetworkPainter extends CustomPainter { _NetworkPainter(this.dark); final bool dark; @override void paint(Canvas canvas, Size s) { final center=Offset(s.width*.52,s.height*.48); final line=Paint()..color=(dark?const Color(0xFF28CBB7):const Color(0xFF3A87D8)).withValues(alpha:.3)..strokeWidth=1.4; final nodes=<({Offset p,IconData i,String l})>[(p:Offset(s.width*.18,s.height*.22),i:Icons.local_hospital_outlined,l:'Hospitals'),(p:Offset(s.width*.82,s.height*.18),i:Icons.airplanemode_active,l:'Air Support'),(p:Offset(s.width*.13,s.height*.66),i:Icons.emergency_outlined,l:'Ambulances'),(p:Offset(s.width*.86,s.height*.65),i:Icons.groups_outlined,l:'Responders'),(p:Offset(s.width*.35,s.height*.86),i:Icons.home_work_outlined,l:'Shelters'),(p:Offset(s.width*.7,s.height*.86),i:Icons.inventory_2_outlined,l:'Supplies')]; for(final n in nodes) { canvas.drawLine(center,n.p,line); canvas.drawCircle(n.p,27,Paint()..color=dark?const Color(0xFF112B42):Colors.white); canvas.drawCircle(n.p,27,Paint()..style=PaintingStyle.stroke..strokeWidth=1.2..color=const Color(0xFF18BFA8).withValues(alpha:.7)); final tp=TextPainter(text:TextSpan(text:String.fromCharCode(n.i.codePoint),style:TextStyle(fontSize:22,fontFamily:n.i.fontFamily,package:n.i.fontPackage,color:const Color(0xFF10B99D))),textDirection:TextDirection.ltr)..layout(); tp.paint(canvas,n.p-Offset(tp.width/2,tp.height/2)); final label=TextPainter(text:TextSpan(text:n.l,style:TextStyle(fontSize:9,fontWeight:FontWeight.w600,color:dark?const Color(0xFFB8C6D7):AppColors.textDim)),textDirection:TextDirection.ltr)..layout(); label.paint(canvas,Offset(n.p.dx-label.width/2,n.p.dy+32)); } canvas.drawCircle(center,52,Paint()..color=const Color(0xFF0BAE94).withValues(alpha:dark?.18:.1)); canvas.drawCircle(center,38,Paint()..color=const Color(0xFF0BAE94)); final icon=TextPainter(text:TextSpan(text:String.fromCharCode(Icons.health_and_safety_rounded.codePoint),style:TextStyle(fontSize:38,fontFamily:Icons.health_and_safety_rounded.fontFamily,color:Colors.white)),textDirection:TextDirection.ltr)..layout(); icon.paint(canvas,center-Offset(icon.width/2,icon.height/2)); } @override bool shouldRepaint(covariant _NetworkPainter old)=>old.dark!=dark; }
class _GridPainter extends CustomPainter { _GridPainter(this.dark); final bool dark; @override void paint(Canvas canvas,Size size){ final p=Paint()..color=(dark?const Color(0xFF5C8BA7):const Color(0xFF6593B2)).withValues(alpha:dark?.045:.035)..strokeWidth=1; for(double x=0;x<size.width;x+=42)canvas.drawLine(Offset(x,0),Offset(x,size.height),p); for(double y=0;y<size.height;y+=42)canvas.drawLine(Offset(0,y),Offset(size.width,y),p);} @override bool shouldRepaint(covariant _GridPainter old)=>old.dark!=dark; }

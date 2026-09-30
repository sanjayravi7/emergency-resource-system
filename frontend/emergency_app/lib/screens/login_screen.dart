import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/socket_service.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_shell.dart';
import 'dispatch_console_page.dart';
import 'responder_readiness_page.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget { const LoginScreen({super.key}); @override State<LoginScreen> createState()=>_LoginScreenState(); }
class _LoginScreenState extends State<LoginScreen> {
  final emailController=TextEditingController(), passwordController=TextEditingController();
  bool loading=false, obscurePassword=true, rememberMe=false; String? errorMessage;
  Future<void> login() async {
    FocusScope.of(context).unfocus();
    if(emailController.text.trim().isEmpty||passwordController.text.isEmpty){setState(()=>errorMessage='Please enter email and password');return;}
    setState((){loading=true;errorMessage=null;});
    try { await ApiService.login(emailController.text.trim(),passwordController.text); SocketService.instance.connect(); if(!mounted)return;
      if(ApiService.isResponder){Navigator.pushReplacement(context,MaterialPageRoute<void>(builder:(readinessContext)=>ResponderReadinessPage(onSaved:(){Navigator.of(readinessContext).pushReplacement(MaterialPageRoute<void>(builder:(_)=>const DispatchConsolePage(readinessSuccess:true)));})));}
      else {Navigator.pushReplacement(context,MaterialPageRoute<void>(builder:(_)=>const DispatchConsolePage()));}
    } catch(error){if(mounted)setState(()=>errorMessage=error.toString().replaceFirst('Exception: ',''));} finally {if(mounted)setState(()=>loading=false);}
  }
  @override void dispose(){emailController.dispose();passwordController.dispose();super.dispose();}
  @override Widget build(BuildContext context){ final dark=Theme.of(context).brightness==Brightness.dark; return AuthShell(child:Container(
    padding:EdgeInsets.all(MediaQuery.sizeOf(context).width<430?22:34),
    decoration:BoxDecoration(color:dark?const Color(0xE6102035):Colors.white,borderRadius:BorderRadius.circular(22),border:Border.all(color:dark?const Color(0xFF2A4C68):AppColors.border),boxShadow:[BoxShadow(color:(dark?const Color(0xFF00BFA8):const Color(0xFF163A61)).withValues(alpha:dark?.1:.09),blurRadius:35,offset:const Offset(0,14))]),
    child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Row(children:[Expanded(child:_tab('Login',true,(){})),Expanded(child:_tab('Register',false,()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const RegisterScreen()))))]),
      const SizedBox(height:28), Center(child:Container(width:54,height:54,decoration:BoxDecoration(color:const Color(0xFF0BAE94).withValues(alpha:.12),shape:BoxShape.circle),child:const Icon(Icons.shield_outlined,color:Color(0xFF0BAE94),size:29))),
      const SizedBox(height:16),Text('Welcome back!',textAlign:TextAlign.center,style:TextStyle(fontSize:27,fontWeight:FontWeight.w800,color:dark?Colors.white:AppColors.text)),
      const SizedBox(height:6),Text('Sign in to continue to ERAS',textAlign:TextAlign.center,style:TextStyle(fontSize:13.5,color:dark?const Color(0xFF9CAFC4):AppColors.textDim)),
      const SizedBox(height:26),TextField(key:const ValueKey('login-email'),controller:emailController,keyboardType:TextInputType.emailAddress,textInputAction:TextInputAction.next,decoration:const InputDecoration(labelText:'Email',prefixIcon:Icon(Icons.mail_outline_rounded))),
      const SizedBox(height:15),TextField(key:const ValueKey('login-password'),controller:passwordController,obscureText:obscurePassword,decoration:InputDecoration(labelText:'Password',prefixIcon:const Icon(Icons.lock_outline_rounded),suffixIcon:IconButton(tooltip:'Show or hide password',onPressed:()=>setState(()=>obscurePassword=!obscurePassword),icon:Icon(obscurePassword?Icons.visibility_outlined:Icons.visibility_off_outlined))),onSubmitted:(_){if(!loading)login();}),
      const SizedBox(height:8),Row(children:[SizedBox(width:24,height:24,child:Checkbox(value:rememberMe,onChanged:(v)=>setState(()=>rememberMe=v??false))),const SizedBox(width:6),Text('Remember me',style:TextStyle(fontSize:12.5,color:dark?const Color(0xFFB4C2D2):AppColors.textDim)),const Spacer()]),
      if(errorMessage!=null)...[const SizedBox(height:10),Container(padding:const EdgeInsets.all(11),decoration:BoxDecoration(color:AppColors.red.withValues(alpha:.1),borderRadius:BorderRadius.circular(10),border:Border.all(color:AppColors.red.withValues(alpha:.2))),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[const Icon(Icons.error_outline,size:18,color:AppColors.red),const SizedBox(width:8),Expanded(child:Text(errorMessage!,style:const TextStyle(fontSize:12.5,color:AppColors.red))) ]))],
      const SizedBox(height:18),DecoratedBox(decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xFF2478E5),Color(0xFF08AA91)]),borderRadius:BorderRadius.circular(12),boxShadow:[BoxShadow(color:const Color(0xFF168BBE).withValues(alpha:.25),blurRadius:16,offset:const Offset(0,7))]),child:FilledButton(onPressed:loading?null:login,style:FilledButton.styleFrom(backgroundColor:Colors.transparent,shadowColor:Colors.transparent),child:loading?const SizedBox(width:19,height:19,child:CircularProgressIndicator(strokeWidth:2,color:Colors.white)):const Row(mainAxisAlignment:MainAxisAlignment.center,children:[Text('Sign in'),SizedBox(width:8),Icon(Icons.arrow_forward_rounded,size:18)]))),
      const SizedBox(height:22),Row(children:[Expanded(child:Divider(color:dark?const Color(0xFF29425F):AppColors.border)),Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Text('SECURE ACCESS',style:TextStyle(fontSize:9.5,letterSpacing:1.2,color:dark?const Color(0xFF71859C):AppColors.textFaint))),Expanded(child:Divider(color:dark?const Color(0xFF29425F):AppColors.border))]),
      const SizedBox(height:17),Wrap(alignment:WrapAlignment.center,spacing:18,runSpacing:8,children:[_trust(Icons.verified_user_outlined,'Encrypted'),_trust(Icons.bolt_outlined,'Real-time'),_trust(Icons.support_agent_outlined,'24/7 ready')]),
    ]))); }
  Widget _tab(String label,bool selected,VoidCallback tap)=>InkWell(onTap:tap,borderRadius:BorderRadius.circular(10),child:Container(padding:const EdgeInsets.symmetric(vertical:12),decoration:BoxDecoration(color:selected?const Color(0xFF1689D9).withValues(alpha:.11):Colors.transparent,borderRadius:BorderRadius.circular(10),border:Border(bottom:BorderSide(color:selected?const Color(0xFF0BAE94):Colors.transparent,width:2))),child:Text(label,textAlign:TextAlign.center,style:TextStyle(fontWeight:FontWeight.w700,color:selected?const Color(0xFF0BAE94):Theme.of(context).colorScheme.onSurfaceVariant))));
  Widget _trust(IconData icon,String text)=>Row(mainAxisSize:MainAxisSize.min,children:[Icon(icon,size:15,color:const Color(0xFF0BAE94)),const SizedBox(width:5),Text(text,style:TextStyle(fontSize:10.5,color:Theme.of(context).colorScheme.onSurfaceVariant))]);
}

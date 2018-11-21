use inc::Module::Install;

RTx('RT-Extension-ElapsedBusinessTime');
license('perl');
requires('Set::Object');
requires('Try::Tiny');

requires_rt '4.0.0';

sign;
&WriteAll;

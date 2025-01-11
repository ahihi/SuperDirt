/*

livecode DSP graphs!

(see livecoding-dsp.tidal for the corresponding Tidal code)

since OSC messages can contain arbitrary strings, we can put sclang code in
them and .interpret it to build synth graphs on the fly.

!!! WARNING !!!
this is a huge security hole if you configure SuperDirt to listen on a non-
loopback network interface - anyone who can send you OSC will be able to
execute arbitrary code on your system.

*/

(
var defaultGdspSynth, eventDiversions, gdspSource;

// the default no-effect global effect synth
defaultGdspSynth = { |dryBus, effectBus, gate=1|
	var dry, wet, sum;
	dry = In.ar(dryBus, ~dirt.numChannels);
	wet = In.ar(effectBus, ~dirt.numChannels);
	EnvGen.kr(Env.asr, gate, doneAction: Done.freeSelf);
	DirtPause.ar(sum, graceTime: 4);
};

// set up global effects
Routine {
	// initialize livecodable global effects with the default no-effect synth
	~dirt.orbits.do { |o, i|
		// each orbit gets its own synthdef name
		SynthDef("dirt-live-global-dsp-%-%".format(i, ~dirt.numChannels).asSymbol, defaultGdspSynth).add;
	};
	// wait for synthdefs to be added
	s.sync;
	// create effects (or recreate if they already exist)
	~dirt.orbits.do { |o, i|
		var insertIx, effect;
		o.globalEffects = o.globalEffects.reject { |fx|
			if(fx.name.asString.beginsWith("dirt-live-global-dsp-")) {
				"release %".format(fx).postln;
				fx.release;
				true;
			} {
				false;
			};
		};
		effect = GlobalDirtEffect("dirt-live-global-dsp-%-".format(i).asSymbol, []).alwaysRun_(true);
		o.globalEffects = o.globalEffects.insert(0, effect);
		o.initNodeTree;
	};
}.();

// set up storage for each orbit's ~gdsp code
gdspSource = nil ! ~dirt.orbits.size;

// define a list of event diversions, which can return nil or a "post-sync
// function". when an event comes in, each diversion is called, and if any of
// them returned post-sync functions, we will sync with the server and call
// those functions. this allows the diversions to define synthdefs, as well as
// code that should run once the synthdefs are ready.
eventDiversions = [
	// handle ~gdsp (code for the orbit's global effect synthdef)
	{ |o, i, dirtEvent|
		var gdspEffect;
		// if the effect code has changed since the last event received,
		// recreate the effect using the new code.
		if(~gdsp != gdspSource[i]) {
			// remember the code so we can keep this synth running until the
			// code changes.
			gdspSource[i] = ~gdsp;
			
			"redefine %".format("dirt-live-global-dsp-%-%".format(i, ~numChannels)).postln;
			SynthDef("dirt-live-global-dsp-%-%".format(i, ~numChannels),
				if(~gdsp.notNil) {
					// if we have some code, wrap it in a function definition
					// to provide the dry signal in the 'in' variable, and
					// interpret.
					//
					// the newline before the closing bracket allows the synth
					// code to include single-line comments.
					{ |dryBus, effectBus, gate=1|
						var dry, wet, sig;
						dry = In.ar(dryBus, ~numChannels);
						// wet = In.ar(effectBus, ~numChannels);
						sig = "{ |in| %\n}".format(~gdsp.asString).interpret.(dry);
						sig = sig * EnvGen.kr(Env.asr, gate, doneAction: Done.freeSelf);
						// DirtPause.ar(sig, graceTime: 4);
						ReplaceOut.ar(dryBus, sig);
					}
				} {
					// if we have no code, restore the default no-effect synth
					defaultGdspSynth
				}
			).add;
			
			gdspEffect = o.globalEffects.detect { |fx| fx.name.asString.beginsWith("dirt-live-global-dsp-") };
			
			// once the synthdef is ready...
			{
				// we want to allow the ~gdsp code to use event variables as
				// controls in NamedControl style, e.g. \freq.kr. this requires
				// specifying the control names in the GlobalDirtEffect's
				// paramNames, which we can do automagically with the help of
				// SynthDescLib!
				gdspEffect.paramNames = SynthDescLib.global[(gdspEffect.name.asString ++ ~numChannels).asSymbol].controls.collect(_.name);

				// finally, start the effect synth
				gdspEffect.play(o.group, o.outBus, o.dryBus, o.globalEffectBus, o.orbitIndex);
			}
		};
	},
	// handle ~dsp (code for the module synthdef)
	{ |o, i, dirtEvent|
		if(~dsp.notNil) {
			// generate temporary synthdef name. by default, these run from
			// 'temp__0' to 'temp__511' and then loop back, so old names
			// eventually get reused and we dont accumulate synthdefs
			// indefinitely.
			~dspSynthDef = SystemSynthDefs.generateTempName;

			// build the synthdef. this synth will run after conventional
			// SuperDirt synths specified with 's' (e.g. dirt_sample), and
			// can process their output!
			SynthDef(~dspSynthDef, { |out|
				var in, sig;
				// wrap the code to be interpreted in a function definition
				// to provide two special variables:
				//
				//   - out: output (and input) bus
				//   - in: input signal from the previous synth
				//
				// everything else is accessible via the event, e.g. ~freq.
				//
				// TODO: should we also do the NamedControl magic here, to
				// enable modulation with control buses?
				in = In.ar(out, ~numChannels);
				sig = "{ |out, in| %\n}" .format(~dsp.asString).interpret.(out, in);
				sig = DirtPan.ar(sig, ~numChannels, ~pan);
				ReplaceOut.ar(out, sig);
			}).add;

			// once the synthdef is ready...
			{
				// play synths. the synthdef name stored in ~dspSynthDef will
				// activate the 'dirt-live-dsp' module, defined below.
				dirtEvent.playSynths;
			}
		};
	}
];

// put the event diversions into place
~dirt.orbits.do { |o, i|
	o.defaultParentEvent[\play] = { |dirtEvent|
		var postSyncFuncs;
		// run in a routine so we can wait for server sync
		Routine {
			// call all the diversions, gathering all the resulting post-sync
			// functions.
			postSyncFuncs = eventDiversions.collect { |d|
				d.(o, i, dirtEvent);
			}.select { |f| f.notNil };

			if(postSyncFuncs.notEmpty) {
				// wait for the server to finish adding the synthdef. this will
				// eat into the time buffer provided by our latency setting, but
				// it should be fine with typical latency settings.
				~server.sync;

				// adjust the latency value to compensate for the time spent
				// syncing.
				~latency = ~timeStamp - thisThread.seconds;

				// run all the post-sync functions
				postSyncFuncs.do { |f|
					f.();
				};
			};
		}.();
	};
};

// define the module which will play our temporary synthdefs.
~dirt.addModule('dirt-live-dsp', { |dirtEvent|
dirtEvent.sendSynth(~dspSynthDef,
	[
		freq: ~freq,
		out: ~out
	]
);	
}, { ~dspSynthDef.notNil });

~dirt.orderModules(['sound', 'dirt-live-dsp']);

// even if our ~dsp code does not use an input signal, a conventional synth
// needs to be specified in 's', otherwise Tidal will not send the event at all.
// thus, it is convenient to have a 'silence' synthdef.
SynthDef(\silence, { |out|
	Out.ar(out, Silent.ar(~dirt.numChannels));
}).add;
)

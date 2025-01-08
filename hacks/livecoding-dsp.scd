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
// first, create an event diversion to build temporary synthdefs from sclang
// code received with the key 'dsp'.
~dirt.orbits.do { |o|
	o.defaultParentEvent[\play] = { |dirtEvent|
		// run in a routine so we can wait for server sync
		Routine {
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
					// the newline before the closing bracket allows the synth
					// code to include single-line comments.
					in = In.ar(out, ~numChannels);
					sig = "{ |out, in| %\n}"
						.format(~dsp.asString).interpret.(out, in);
					sig = DirtPan.ar(sig, ~numChannels, ~pan);
					ReplaceOut.ar(out, sig);
				}).add;

				// wait for the server to finish adding the synthdef. this will
				// eat into the time buffer provided by our latency setting - in
				// testing done by pulu, we typically spend about 20ms waiting.
				~server.sync;

				// adjust the latency value to compensate for the time spent
				// syncing.
				~latency = ~timeStamp - thisThread.seconds;
			};

			// play synths. the synthdef name stored in ~dspSynthDef will
			// activate the 'dirt-live-dsp' module, defined below.
			//
			// to bypass SuperDirt's default event playback path, we need to
			// return non-nil from here, which .playSynths does,
			dirtEvent.playSynths;
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

// even if our livecoded dsp doesnt use an input signal, a conventional synth
// needs to be specified in 's', otherwise Tidal will not send the event at all.
// thus, it is convenient to have a 'silence' synthdef.
SynthDef(\silence, { |out|
	Out.ar(out, Silent.ar(~dirt.numChannels));
}).add;
)

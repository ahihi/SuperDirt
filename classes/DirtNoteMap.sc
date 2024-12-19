// a note map is a function that takes as argument a midi note number

DirtNoteMap {
	*closest { |notes|
		notes = notes.collect { |note, n|
			(note: note, n: n)
		}.sort { |a, b| a.note < b.note };
		
		^{
			var midinote = ~midinote.();
			var lastDist = inf;
			var dist;
			block { |ret|
				notes.do { |candidate, i|
					dist = (midinote - candidate.note).abs;
					if(dist >= lastDist) {
						ret.(notes[i-1]);
					};
					lastDist = dist;
				};
				ret.(notes[notes.size - 1]);
			}
		}
	}
}
